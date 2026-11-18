import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

struct ADBSyncTests {
  typealias Peer = FakeADBServer.Peer

  private static let fiveGB: UInt64 = 5 * 1024 * 1024 * 1024

  private func sync(
    _ features: Set<String>, script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> (ADBSync, FakeADBServer) {
    try await SyncFixture.sync(features, script: script)
  }

  private func scratchFile(_ bytes: Data? = nil) throws -> (URL, FileHandle) {
    try SyncFixture.scratchFile(bytes)
  }

  // MARK: stat

  @Test func statV1ReadsThreeLittleEndianWords() async throws {
    let (sync, server) = try await sync([]) { peer in
      let request = try await peer.syncPathRequest()
      #expect(request.id == "STAT" && request.path == "/sdcard/a.txt")
      try await peer.raw(Peer.stat(mode: 0o100644, size: 1234, mtime: 1_700_000_000))
    }
    defer { server.stop() }
    let stat = try #require(try await sync.stat("/sdcard/a.txt"))
    #expect(stat.mode == 0o100644 && stat.size == 1234)
    #expect(stat.mtime == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(stat.isRegular && !stat.isDirectory)
  }

  @Test func statV2CarriesA64BitSize() async throws {
    let (sync, server) = try await sync(["stat_v2"]) { peer in
      let request = try await peer.syncPathRequest()
      #expect(request.id == "STA2")
      try await peer.raw(
        Peer.sta2(mode: 0o100600, size: Self.fiveGB, mtime: 1_700_000_001))
    }
    defer { server.stop() }
    let stat = try #require(try await sync.stat("/sdcard/big.mkv"))
    #expect(stat.size == Self.fiveGB)
    #expect(stat.mtime == Date(timeIntervalSince1970: 1_700_000_001))
  }

  @Test func aMissingPathIsNilOnBothProtocols() async throws {
    let (withV2, server2) = try await sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.sta2(error: 2, mode: 0, size: 0, mtime: 0))
    }
    defer { server2.stop() }
    #expect(try await withV2.stat("/nope") == nil)
    let (withV1, server1) = try await sync([]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0, size: 0, mtime: 0))
    }
    defer { server1.stop() }
    #expect(try await withV1.stat("/nope") == nil)
  }

  @Test func otherStatErrorsAreFailures() async throws {
    let (sync, server) = try await sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.sta2(error: 13, mode: 0, size: 0, mtime: 0))
    }
    defer { server.stop() }
    await #expect(throws: ADBError.failed("stat /secret failed with errno 13")) {
      _ = try await sync.stat("/secret")
    }
  }

  // MARK: list

  @Test func listV2ReadsEntriesAndDropsDotEntries() async throws {
    let (sync, server) = try await sync(["stat_v2", "ls_v2"]) { peer in
      let request = try await peer.syncPathRequest()
      #expect(request.id == "LIS2" && request.path == "/sdcard")
      try await peer.raw(
        Peer.dnt2(name: ".", mode: 0o040755, size: 4096, mtime: 1)
          + Peer.dnt2(name: "..", mode: 0o040755, size: 4096, mtime: 1)
          + Peer.dnt2(name: "big.mkv", mode: 0o100600, size: Self.fiveGB, mtime: 1_700_000_002)
          + Peer.dnt2(name: "Music \u{1F3B5}", mode: 0o040771, size: 4096, mtime: 3)
          + Peer.listDone(extended: true))
    }
    defer { server.stop() }
    let entries = try await sync.list("/sdcard")
    #expect(entries.map(\.name) == ["big.mkv", "Music \u{1F3B5}"])
    #expect(entries[0].stat.size == Self.fiveGB)
    #expect(entries[1].stat.isDirectory)
  }

  @Test func withoutLsV2RegularFilesAreRestatedSoLargeSizesAreRight() async throws {
    let truncated = UInt32(truncatingIfNeeded: Self.fiveGB)
    let (sync, server) = try await sync(["stat_v2"]) { peer in
      let list = try await peer.syncPathRequest()
      #expect(list.id == "LIST" && list.path == "/sdcard/DCIM/")
      try await peer.raw(
        Peer.dent(name: "big.mkv", mode: 0o100600, size: truncated, mtime: 5)
          + Peer.dent(name: "sub", mode: 0o040771, size: 4096, mtime: 6)
          + Peer.listDone(extended: false))
      let restat = try await peer.syncPathRequest()
      #expect(restat.id == "STA2" && restat.path == "/sdcard/DCIM/big.mkv")
      try await peer.raw(Peer.sta2(mode: 0o100600, size: Self.fiveGB, mtime: 5))
      // The directory is not re-statted: the next request is the test's QUIT.
      let next = try await peer.syncHeader()
      #expect(next.id == "QUIT")
    }
    defer { server.stop() }
    let entries = try await sync.list("/sdcard/DCIM/")
    #expect(entries.map(\.name) == ["big.mkv", "sub"])
    #expect(entries[0].stat.size == Self.fiveGB)
    #expect(entries[1].stat.size == 4096)
    await sync.quit()
  }

  @Test func listFailureIsMapped() async throws {
    let (sync, server) = try await sync(["stat_v2", "ls_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.fail("Permission denied"))
    }
    defer { server.stop() }
    await #expect(throws: ADBError.failed("Permission denied")) { _ = try await sync.list("/x") }
  }
}
