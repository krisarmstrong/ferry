import Foundation
import Testing

@testable import ADBTransport

/// One sync connection's life: requests take turns, and an error ends it.
@Suite(.timeLimit(.minutes(1)))
struct ADBSyncSessionTests {
  typealias Peer = FakeADBServer.Peer

  private func isViolation(_ error: any Error) -> Bool {
    if case .protocolViolation = error as? ADBError { return true }
    return false
  }

  // MARK: turn-taking

  @Test func concurrentRequestsTakeTurnsAndKeepTheirOwnReplies() async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      for _ in 0..<2 {
        let request = try await peer.syncPathRequest()
        let reply = Peer.lst2(mode: 0o100600, size: request.path == "/a" ? 111 : 222, mtime: 1)
        // A reply that arrives in two parts leaves room for a second request to barge in.
        try await peer.raw(reply.prefix(10))
        try await Task.sleep(for: .milliseconds(100))
        try await peer.raw(reply.dropFirst(10))
      }
    }
    defer { server.stop() }
    async let first = sync.stat("/a")
    async let second = sync.stat("/b")
    let (one, two) = try await (first, second)
    #expect(one?.size == 111)
    #expect(two?.size == 222)
  }

  // MARK: outgoing paths

  @Test(arguments: [1024, 1025])
  func requestPathsAreCappedAt1024Bytes(_ length: Int) async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.lst2(mode: 0o100600, size: 5, mtime: 1))
    }
    defer { server.stop() }
    let path = "/" + String(repeating: "p", count: length - 1)
    if length <= 1024 {
      #expect(try await sync.stat(path)?.size == 5)
    } else {
      await #expect(throws: ADBError.invalidArgument(path)) { _ = try await sync.stat(path) }
    }
  }

  @Test func sendCountsTheModeSuffixAgainstTheCap() async throws {
    let (sync, server) = try await SyncFixture.sync([]) { _ in }
    defer { server.stop() }
    let (url, handle) = try SyncFixture.scratchFile(Data(count: 1))
    defer { try? FileManager.default.removeItem(at: url) }
    try handle.seek(toOffset: 0)
    // "<path>,33188" is 6 bytes longer than the path.
    let path = "/" + String(repeating: "p", count: 1024 - 6)
    await #expect(throws: ADBError.invalidArgument(path)) {
      try await sync.send(handle, to: path, mode: 0o100644, mtime: .now) { _, _ in true }
    }
  }

  @Test func aRefusedPathLeavesTheConnectionUsable() async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.lst2(mode: 0o100600, size: 9, mtime: 1))
    }
    defer { server.stop() }
    let tooLong = String(repeating: "p", count: 2000)
    await #expect(throws: ADBError.invalidArgument(tooLong)) { _ = try await sync.stat(tooLong) }
    #expect(try await sync.stat("/ok")?.size == 9)
  }

  // MARK: after an error

  private static let closed = ADBError.connectionClosed

  @Test func afterAFailOnReceiveTheConnectionIsDead() async throws {
    let hungUp = Latch()
    let (sync, server) = try await SyncFixture.sync([]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0o100600, size: 1, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.fail("open failed"))
      _ = try? await peer.stream.read(exactly: 1)
      hungUp.fire()
    }
    defer { server.stop() }
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect(throws: ADBError.failed("open failed")) {
      _ = try await sync.receive("/x", to: handle) { _, _ in true }
    }
    await hungUp.wait()
    await #expect(throws: Self.closed) { _ = try await sync.stat("/y") }
    await #expect(throws: Self.closed) { _ = try await sync.list("/y").entries }
  }

  @Test func afterAnUnreadableReplyIdTheConnectionIsClosedAndDead() async throws {
    let hungUp = Latch()
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Data([0xFF, 0xFE, 0xFF, 0xFE]))
      _ = try? await peer.stream.read(exactly: 1)
      hungUp.fire()
    }
    defer { server.stop() }
    await #expect { _ = try await sync.stat("/x") } throws: { isViolation($0) }
    await hungUp.wait()
    await #expect(throws: Self.closed) { _ = try await sync.stat("/x") }
  }

  @Test func afterAProtocolViolationTheConnectionIsDead() async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Data("NOPE".utf8))
    }
    defer { server.stop() }
    await #expect { _ = try await sync.stat("/x") } throws: { isViolation($0) }
    await #expect(throws: Self.closed) { _ = try await sync.stat("/x") }
  }

  @Test func afterAStatErrnoTheConnectionIsDead() async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.lst2(error: 13, mode: 0, size: 0, mtime: 0))
    }
    defer { server.stop() }
    await #expect(throws: ADBError.failed("stat /x failed with errno 13")) {
      _ = try await sync.stat("/x")
    }
    await #expect(throws: Self.closed) { _ = try await sync.stat("/x") }
  }

  @Test func quitOnADeadConnectionIsHarmless() async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.lst2(error: 13, mode: 0, size: 0, mtime: 0))
    }
    defer { server.stop() }
    _ = try? await sync.stat("/x")
    await sync.quit()
  }

  // MARK: stat and listing details

  @Test(arguments: [2, 20] as [UInt32])
  func aMissingOrNonDirectoryParentIsNil(_ errno: UInt32) async throws {
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.lst2(error: errno, mode: 0, size: 0, mtime: 0))
    }
    defer { server.stop() }
    #expect(try await sync.stat("/file/child") == nil)
  }

  @Test(arguments: [0, 1])
  func aListingIsCappedAtTheEntryLimit(_ extra: Int) async throws {
    let limit = 50
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      _ = try await peer.syncPathRequest()
      let entry = Peer.dent(name: "n", mode: 0o100600, size: 1, mtime: 1)
      try await peer.raw(Data((0..<(limit + extra)).map { _ in entry }.joined()))
      try await peer.raw(Peer.listDone(extended: false))
    }
    defer { server.stop() }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let stream = try await host.connect("S", service: "sync:", transportID: nil)
    let sync = ADBSync(stream: stream, features: [], entryLimit: limit)
    if extra == 0 {
      #expect(try await sync.list("/x").entries.count == limit)
    } else {
      await #expect { _ = try await sync.list("/x").entries } throws: { isViolation($0) }
    }
  }

  @Test func theDefaultEntryLimitIsAMillion() {
    #expect(ADBSync.defaultEntryLimit == 1_000_000)
  }

  // MARK: cancellation and teardown

  /// The first reply waits until the queued request has been cancelled.
  @Test func aQueuedRequestInACancelledTaskDoesNotRunAndTheConnectionSurvives() async throws {
    let sawFirst = Latch()
    let (cancelled, cancelledQueued) = AsyncStream.makeStream(of: Void.self)
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      let first = try await peer.syncPathRequest()
      #expect(first.path == "/first")
      sawFirst.fire()
      for await _ in cancelled { break }
      try await peer.raw(Peer.lst2(mode: 0o100600, size: 1, mtime: 1))
      // The cancelled "/queued" request must never arrive: the next one is "/last".
      let next = try await peer.syncPathRequest()
      #expect(next.path == "/last")
      try await peer.raw(Peer.lst2(mode: 0o100600, size: 3, mtime: 1))
    }
    defer { server.stop() }
    let first = Task { try await sync.stat("/first") }
    await sawFirst.wait()
    let queued = Task { try await sync.stat("/queued") }
    #expect(try await eventually { await sync.queuedRequests == 1 })
    queued.cancel()
    cancelledQueued.yield()
    #expect(try await first.value?.size == 1)
    await #expect(throws: ADBError.cancelled) { _ = try await queued.value }
    #expect(try await sync.stat("/last")?.size == 3)
  }

  @Test func quitReturnsAtOnceWhileARequestIsWedgedAndFailsIt() async throws {
    let sawRequest = Latch()
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      sawRequest.fire()
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let wedged = Task { try await sync.stat("/never-answered") }
    await sawRequest.wait()
    await sync.quit()
    await #expect { _ = try await wedged.value } throws: { $0 is ADBError }
    await #expect(throws: Self.closed) { _ = try await sync.stat("/x") }
  }

  // MARK: re-stat of long child paths

  @Test func anOverlongChildPathKeepsItsListSizeInsteadOfFailingTheListing() async throws {
    let truncated = UInt32(truncatingIfNeeded: 5 * 1024 * 1024 * 1024)
    let directory = "/" + String(repeating: "d", count: 1000)
    let longName = String(repeating: "n", count: 100)
    let (sync, server) = try await SyncFixture.sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(
        Peer.dent(name: longName, mode: 0o100600, size: 123, mtime: 5)
          + Peer.dent(name: "short.bin", mode: 0o100600, size: truncated, mtime: 6)
          + Peer.listDone(extended: false))
      // Only the short name is re-statted.
      let restat = try await peer.syncPathRequest()
      #expect(restat.id == "STA2" && restat.path == directory + "/short.bin")
      try await peer.raw(Peer.sta2(mode: 0o100600, size: 5 * 1024 * 1024 * 1024, mtime: 6))
      let next = try await peer.syncHeader()
      #expect(next.id == "QUIT")
    }
    defer { server.stop() }
    let entries = try await sync.list(directory).entries
    #expect(entries.map(\.name) == [longName, "short.bin"])
    #expect(entries[0].stat.size == 123)
    #expect(entries[1].stat.size == 5 * 1024 * 1024 * 1024)
    await sync.quit()
  }
}
