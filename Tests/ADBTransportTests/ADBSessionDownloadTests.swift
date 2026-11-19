import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// `download` on `ADBSession`, and losing the device, against `MTPSession`'s contracts.
struct ADBSessionDownloadTests {
  let storage = ADBFixture.storage

  func path(_ string: String) throws -> RemotePath { try ADBFixture.path(string) }

  // MARK: Download

  @Test func downloadWritesTheFileAndReportsWhatArrived() async throws {
    let device = FakeAndroid()
    let contents = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
    device.addFile("/big.bin", contents, mtime: 1_700_000_005)
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "big.bin")
    let downloaded = try await ADBFixture.withSession(device) { session in
      try await session.download(
        path("/big.bin"), in: storage, to: file, replacing: false, progress: ADBFixture.noProgress)
    }
    #expect(try Data(contentsOf: file) == contents)
    #expect(downloaded.received == 150_000)
    #expect(downloaded.listed.modified == Date(timeIntervalSince1970: 1_700_000_005))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["big.bin"])
  }

  @Test(arguments: [false, true])
  func anExistingFileIsReplacedOnlyWhenAsked(replacing: Bool) async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("device".utf8))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "a.txt")
    try Data("mac".utf8).write(to: file)
    let remote = try path("/a.txt")
    try await ADBFixture.withSession(device) { session in
      if replacing {
        try await session.download(
          remote, in: storage, to: file, replacing: true, progress: ADBFixture.noProgress)
      } else {
        await #expect(throws: TransportError.alreadyExists(remote)) {
          try await session.download(
            remote, in: storage, to: file, replacing: false, progress: ADBFixture.noProgress)
        }
      }
    }
    #expect(try Data(contentsOf: file) == Data((replacing ? "device" : "mac").utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.txt"])
  }

  @Test func aFileThatAppearsDuringTheDownloadIsKept() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("device".utf8))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "a.txt")
    await #expect(throws: TransportError.alreadyExists(try path("/a.txt"))) {
      try await ADBFixture.withSession(device) { session in
        let createFileMeanwhile: ProgressHandler = { _, _ in
          FileManager.default.createFile(atPath: file.path, contents: Data("mac".utf8))
          return true
        }
        try await session.download(
          path("/a.txt"), in: storage, to: file, replacing: false, progress: createFileMeanwhile)
      }
    }
    #expect(try Data(contentsOf: file) == Data("mac".utf8))
  }

  @Test(arguments: ["/missing.txt", "/Folder"])
  func downloadingAMissingFileOrAFolderIsNotFound(_ name: String) async throws {
    let device = FakeAndroid()
    device.addFolder("/Folder")
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    await #expect(throws: TransportError.notFound(try path(name))) {
      try await ADBFixture.withSession(device) { session in
        try await session.download(
          path(name), in: storage, to: folder.appending(path: "x"), replacing: false,
          progress: ADBFixture.noProgress)
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test func aCancelledDownloadLeavesNothingAndTheSessionCarriesOn() async throws {
    let device = FakeAndroid()
    device.addFile("/big.bin", Data(count: 200_000))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.cancelled) {
        try await session.download(
          path("/big.bin"), in: storage, to: folder.appending(path: "big.bin"), replacing: false
        ) { _, _ in false }
      }
      let listed = try await session.list(.root, in: storage)
      #expect(listed.count == 1)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  /// The device listed more than it sent: the file shrank. One more try, then it is reported.
  @Test func aShortDownloadIsTriedOnceMoreThenReported() async throws {
    let device = FakeAndroid()
    device.addFile("/a.bin", Data(count: 10))
    for size in [4, 2] {
      device.beforeNextSync("RECV") { $0.addFile("/a.bin", Data(count: size)) }
    }
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    await #expect(throws: TransportError.downloadSizeMismatch(listed: 4, received: 2)) {
      try await ADBFixture.withSession(device) { session in
        try await session.download(
          path("/a.bin"), in: storage, to: folder.appending(path: "a.bin"), replacing: false,
          progress: ADBFixture.noProgress)
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test func aFileThatGrewIsKeptWhole() async throws {
    let device = FakeAndroid()
    device.addFile("/a.bin", Data(count: 10))
    device.beforeNextSync("RECV") { $0.addFile("/a.bin", Data(count: 15)) }
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let downloaded = try await ADBFixture.withSession(device) { session in
      try await session.download(
        path("/a.bin"), in: storage, to: folder.appending(path: "a.bin"), replacing: false,
        progress: ADBFixture.noProgress)
    }
    #expect(downloaded.listed.size == 10)
    #expect(downloaded.item.size == 15)
  }

  // MARK: Losing the device

  @Test func anUnpluggedDeviceIsDisconnectedFromThenOn() async throws {
    let device = FakeAndroid()
    device.addFile("/big.bin", Data(count: 200_000))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    device.dropDuring("RECV", afterBytes: 65_536)
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.deviceDisconnected) {
        try await session.download(
          path("/big.bin"), in: storage, to: folder.appending(path: "big.bin"), replacing: false,
          progress: ADBFixture.noProgress)
      }
      #expect(await session.capabilities().isEmpty)
      let requests = device.syncRequests.count
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await session.list(.root, in: storage)
      }
      #expect(device.syncRequests.count == requests)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  /// A connection that drops mid-request while the device stays is an I/O failure; the next
  /// call reconnects.
  @Test func aDroppedConnectionToAPresentDeviceIsNotADisconnect() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    try await ADBFixture.withSession(device) { session in
      // The session's first request, on a connection it has just opened.
      device.beforeNextSync("LST2") { $0.dropConnections() }
      await #expect {
        _ = try await session.list(.root, in: storage)
      } throws: { error in
        guard case .io = error as? TransportError else { return false }
        return true
      }
      let listed = try await session.list(.root, in: storage)
      #expect(listed.count == 1)
      #expect(await session.capabilities() == [.move])
    }
  }

  /// A kept connection closes only when its transport ends (the device or the server went away,
  /// perhaps to return at once), so the session is over even if the device answers again.
  @Test func aKeptConnectionThatClosesIsADisconnect() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    try await ADBFixture.withSession(device) { session in
      _ = try await session.list(.root, in: storage)
      device.dropConnections()
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await session.list(.root, in: storage)
      }
      #expect(await session.capabilities().isEmpty)
    }
  }
}
