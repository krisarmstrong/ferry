import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// The transport's narrower guarantees: what a session asks the server, what a scan-time
/// failure costs, and the bounds a hostile device meets.
struct ADBMinorFixTests {
  typealias Peer = FakeADBServer.Peer
  let storage = ADBFixture.storage

  /// The session already knows the device's features: its commands do not ask again.
  @Test func sessionCommandsDoNotAskForFeatures() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    try await ADBFixture.withSession(device) { session in
      _ = try await session.makeFolder(RemotePath("/New"), in: storage)
      _ = try await session.rename(RemotePath("/a.txt"), to: "b.txt", in: storage)
      try await session.delete(RemotePath("/b.txt"), in: storage)
    }
    #expect(device.featureQueries == 0)
  }

  /// A cancelled task cannot ask whether the device is there; that is not the device leaving.
  @Test func aCancelledReachabilityCheckIsNotADisconnect() async throws {
    let device = FakeAndroid()
    try await ADBFixture.withSession(device) { session in
      let checked = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await session.failure(.connectionClosed, ADBSession.Step("listing", .root))
      }
      #expect(await checked.value != .deviceDisconnected)
    }
  }

  /// A file that cannot be stat'ed (a folder that is readable but not searchable) keeps the
  /// size its listing gave; the listing still succeeds.
  @Test func aStatErrorWhileCorrectingSizesKeepsTheListedSize() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("abc".utf8))
    device.addFile("/b.txt", Data("de".utf8))
    device.state.withLock {
      $0.statErrors[FakeAndroid.internalPath("/a.txt")] = 13
    }
    try await ADBFixture.withSession(device) { session in
      let sizes = try await session.list(.root, in: storage).map(\.size).sorted()
      #expect(sizes == [2, 3])
    }
  }

  /// Entries a listing leaves out still count toward its cap, so a device cannot stream them
  /// forever.
  @Test(.timeLimit(.minutes(1)))
  func leftOutEntriesCountTowardTheCap() async throws {
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      _ = try await peer.syncPathRequest()
      let bad = Data([0xFF, 0xFE])
      let entry =
        Data("DENT".utf8) + Peer.le32(0o100600) + Peer.le32(1) + Peer.le32(1)
        + Peer.le32(UInt32(bad.count)) + bad
      for _ in 0..<10 { try await peer.raw(entry) }
      try await peer.raw(Peer.listDone(extended: false))
    }
    defer { server.stop() }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let stream = try await host.connect("S", service: "sync:", transportID: nil)
    let sync = ADBSync(stream: stream, features: [], entryLimit: 3)
    await #expect {
      _ = try await sync.list("/x")
    } throws: { error in
      if case .protocolViolation = error as? ADBError { return true }
      return false
    }
  }

  /// A device that keeps sending past the size it reported is stopped once it is well past it.
  @Test(.timeLimit(.minutes(1)))
  func aDownloadThatGrowsPastItsSizeIsStopped() async throws {
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.sta2(mode: 0o100600, size: 10, mtime: 1))
      _ = try await peer.syncPathRequest()
      let chunk = Peer.data(Data(repeating: 7, count: 1024))
      while true { try await peer.raw(chunk) }
    }
    defer { server.stop() }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let stream = try await host.connect("S", service: "sync:", transportID: nil)
    let sync = ADBSync(
      stream: stream, features: ["stat_v2"], entryLimit: ADBSync.defaultEntryLimit,
      growthAllowance: 4096)
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect {
      _ = try await sync.receive("/x", to: handle, progress: { _, _ in true })
    } throws: { error in
      if case .protocolViolation = error as? ADBError { return true }
      return false
    }
  }

  /// The device reports the size: one at the type's maximum must not overflow the growth check.
  @Test(.timeLimit(.minutes(1)))
  func aDownloadDeclaringTheLargestSizeDoesNotTrap() async throws {
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.sta2(mode: 0o100600, size: .max, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.data(Data("abc".utf8)) + Peer.done())
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let stream = try await host.connect("S", service: "sync:", transportID: nil)
    let sync = ADBSync(stream: stream, features: ["stat_v2"])
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await sync.receive("/x", to: handle, progress: { _, _ in true }) == 3)
  }

  /// The cap runs from the smaller of the listed size and the size the device gives at
  /// download time: a stat of `UInt64.max` after a small listing does not turn it off.
  @Test(.timeLimit(.minutes(1)))
  func aLargerDownloadTimeStatDoesNotLiftTheCap() async throws {
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.sta2(mode: 0o100600, size: .max, mtime: 1))
      _ = try await peer.syncPathRequest()
      let chunk = Peer.data(Data(repeating: 7, count: 1024))
      for _ in 0..<16 { try await peer.raw(chunk) }
      try await peer.raw(Peer.done())
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let stream = try await host.connect("S", service: "sync:", transportID: nil)
    let sync = ADBSync(
      stream: stream, features: ["stat_v2"], entryLimit: ADBSync.defaultEntryLimit,
      growthAllowance: 4096)
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect {
      _ = try await sync.receive("/x", to: handle, listedSize: 10, progress: { _, _ in true })
    } throws: { error in
      if case .protocolViolation = error as? ADBError { return true }
      return false
    }
  }

  /// A symlink is not a folder, on every protocol: the check never follows it.
  @Test(arguments: ["cmd,shell_v2,stat_v2", "cmd,shell_v2"])
  func aSymlinkToAFolderIsNotAFolder(features: String) async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.features = features }
    device.addFolder("/Real")
    device.addFile("/Real/a.txt", Data("a".utf8))
    device.addRaw(
      "/", name: Array("Link".utf8), node: .link(FakeAndroid.internalPath("/Real")))
    let server = try await device.serve(serial: ADBFixture.serial)
    defer { server.stop() }
    let session = ADBSession(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), serial: ADBFixture.serial,
      transportID: nil, info: ADBFixture.info,
      features: Set(features.split(separator: ",").map(String.init)),
      method: .usbADB)
    let link = try RemotePath("/Link")
    await #expect(throws: TransportError.notFound(link)) {
      _ = try await session.list(link, in: storage)
    }
    await session.close()
  }

  /// The session does not offer a copy it cannot make.
  @Test func aSessionOffersMoveOnly() async throws {
    try await ADBFixture.withSession(FakeAndroid()) { session in
      #expect(await session.capabilities() == [.move])
    }
  }

  /// An eject that lands while an open waits for the device is honoured: no session is handed
  /// out for an ejected device.
  @Test func anEjectDuringAnOpenWins() async throws {
    let id = TransportFixture.linkRunner
    let android = TransportFixture.android(serial: TransportFixture.linkRunnerSerial)
    let hub = try await TransportFixture.hub([
      .init(TransportFixture.linkRunnerSerial, device: android)
    ])
    let transport = TransportFixture.transport(port: hub.port)
    #expect(try await transport.scan().devices.map(\.id) == [id])
    android.state.withLock { $0.beforeFeatures = { await transport.park(id) } }
    await #expect(throws: TransportError.deviceNotFound(id)) {
      _ = try await transport.open(id)
    }
    android.state.withLock { $0.beforeFeatures = nil }
    #expect(await transport.sessionRoute(for: id) == nil)
    #expect(try await transport.scan().ejected.map(\.id) == [id])
    await hub.kill()
  }
}
