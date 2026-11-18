import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

struct ADBSyncTransferTests {
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

  // MARK: receive

  @Test func receiveWritesChunksAndReportsProgressAgainstTheStatSize() async throws {
    let payload = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
    let (sync, server) = try await sync(["stat_v2"]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.sta2(mode: 0o100600, size: 150_000, mtime: 1))
      let request = try await peer.syncPathRequest()
      #expect(request.id == "RECV" && request.path == "/sdcard/a.bin")
      try await peer.raw(
        Peer.data(payload[0..<65_536]) + Peer.data(payload[65_536..<131_072])
          + Peer.data(payload[131_072...]) + Peer.done())
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let ticks = Box<[[UInt64]]>([])
    let written = try await sync.receive("/sdcard/a.bin", to: handle) { done, total in
      Task { await ticks.set(await ticks.value + [[done, total]]) }
      return true
    }
    try handle.close()
    #expect(written == 150_000)
    #expect(try Data(contentsOf: url) == payload)
    try await Task.sleep(for: .milliseconds(100))
    #expect(
      Set(await ticks.value) == Set([[65_536, 150_000], [131_072, 150_000], [150_000, 150_000]]))
  }

  @Test func receiveFailureIsMapped() async throws {
    let (sync, server) = try await sync([]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0o100600, size: 10, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.fail("open failed: Permission denied"))
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect(throws: ADBError.failed("open failed: Permission denied")) {
      _ = try await sync.receive("/x", to: handle) { _, _ in true }
    }
  }

  @Test func receiveStoppedByProgressThrowsCancelledAndHangsUp() async throws {
    let hungUp = Box(false)
    let (sync, server) = try await sync([]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0o100600, size: 200_000, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.data(Data(count: 65_536)) + Peer.data(Data(count: 65_536)))
      // The client abandons the transfer: its socket closes with the rest unsent.
      _ = try? await peer.stream.read(exactly: 1)
      await hungUp.set(true)
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect(throws: ADBError.cancelled) {
      _ = try await sync.receive("/x", to: handle) { _, _ in false }
    }
    for _ in 0..<100 where await !hungUp.value { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await hungUp.value)
    // Only the first chunk, the one the handler stopped on, reached the file.
    try handle.close()
    #expect(try Data(contentsOf: url) == Data(count: 65_536))
  }

  @Test func receiveRefusesAnOversizedChunk() async throws {
    let (sync, server) = try await sync([]) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0o100600, size: 10, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Data("DATA".utf8) + Peer.le32(65_537))
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect {
      _ = try await sync.receive("/x", to: handle) { _, _ in true }
    } throws: {
      if case .protocolViolation = $0 as? ADBError { return true }
      return false
    }
  }

  // MARK: send

  @Test func sendChunksAt64KiBAndCarriesMtimeOnDone() async throws {
    let payload = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let received = Box(Data())
    let chunks = Box<[Int]>([])
    let doneMtime = Box<UInt32>(0)
    let target = Box("")
    let (sync, server) = try await sync([]) { peer in
      let header = try await peer.syncHeader()
      #expect(header.id == "SEND")
      await target.set(
        try ADBWire.text(try await peer.stream.read(exactly: Int(header.length))))
      while true {
        let next = try await peer.syncHeader()
        if next.id == "DONE" {
          await doneMtime.set(next.length)
          break
        }
        #expect(next.id == "DATA")
        let body = try await peer.stream.read(exactly: Int(next.length))
        await chunks.set(await chunks.value + [body.count])
        await received.set(await received.value + body)
      }
      try await peer.raw(Data("OKAY".utf8) + Peer.le32(0))
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile(payload)
    defer { try? FileManager.default.removeItem(at: url) }
    try handle.seek(toOffset: 0)
    let last = Box<[UInt64]>([])
    try await sync.send(
      handle, to: "/sdcard/up.bin", mode: 0o100644,
      mtime: Date(timeIntervalSince1970: 1_700_000_000)
    ) { done, total in
      Task { await last.set([done, total]) }
      return true
    }
    #expect(await target.value == "/sdcard/up.bin,33188")
    #expect(await chunks.value == [65_536, 65_536, 18_928])
    #expect(await received.value == payload)
    #expect(await doneMtime.value == 1_700_000_000)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await last.value == [150_000, 150_000])
  }

  @Test func sendFailureAfterDoneIsMapped() async throws {
    let (sync, server) = try await sync([]) { peer in
      let header = try await peer.syncHeader()
      _ = try await peer.stream.read(exactly: Int(header.length))
      while true {
        let next = try await peer.syncHeader()
        if next.id == "DONE" { break }
        _ = try await peer.stream.read(exactly: Int(next.length))
      }
      try await peer.raw(Peer.fail("No space left on device"))
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile(Data(count: 10))
    defer { try? FileManager.default.removeItem(at: url) }
    try handle.seek(toOffset: 0)
    await #expect(throws: ADBError.failed("No space left on device")) {
      try await sync.send(handle, to: "/x", mode: 0o100644, mtime: .now) { _, _ in true }
    }
  }

  @Test func sendStoppedByProgressNeverSendsDone() async throws {
    let sawDone = Box(false)
    let hungUp = Box(false)
    let (sync, server) = try await sync([]) { peer in
      let header = try await peer.syncHeader()
      _ = try await peer.stream.read(exactly: Int(header.length))
      do {
        while true {
          let next = try await peer.syncHeader()
          if next.id == "DONE" { await sawDone.set(true) }
          if next.id == "DATA" { _ = try await peer.stream.read(exactly: Int(next.length)) }
        }
      } catch {
        await hungUp.set(true)
      }
    }
    defer { server.stop() }
    let (url, handle) = try scratchFile(Data(count: 200_000))
    defer { try? FileManager.default.removeItem(at: url) }
    try handle.seek(toOffset: 0)
    await #expect(throws: ADBError.cancelled) {
      try await sync.send(handle, to: "/x", mode: 0o100644, mtime: .now) { _, _ in false }
    }
    for _ in 0..<100 where await !hungUp.value { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await hungUp.value)
    #expect(await !sawDone.value)
  }

  // MARK: quit

  @Test func quitSendsQuitAndClosesTheConnection() async throws {
    let saw = Box("")
    let (sync, server) = try await sync([]) { peer in
      let header = try await peer.syncHeader()
      await saw.set("\(header.id) \(header.length)")
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    await sync.quit()
    for _ in 0..<100 where await saw.value.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await saw.value == "QUIT 0")
  }
}
