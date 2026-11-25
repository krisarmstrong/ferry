import Foundation
import Testing

@testable import ADBTransport

/// Every length a peer supplies is capped before it is read, at the limit and one past it.
@Suite(.timeLimit(.minutes(1)))
struct ADBLimitsTests {
  typealias Peer = FakeADBServer.Peer

  private static let packetLimit = 64 * 1024
  private static let nameLimit = 4096
  private static let outputLimit = 16 * 1024 * 1024
  private static let token = "limit-token"

  private func isViolation(_ error: any Error) -> Bool {
    if case .protocolViolation = error as? ADBError { return true }
    return false
  }

  // MARK: shell

  private func run(
    features: String, service: String, script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> ADBShellResult {
    let fixture = ADBHostRunTests()
    let server = try await fixture.server(features: features, service: service, shell: script)
    defer { server.stop() }
    return try await fixture.host(server).run(
      serial: "S", command: "x", token: Self.token, transportID: nil)
  }

  @Test(arguments: [Self.packetLimit, Self.packetLimit + 1])
  func shellV2PacketLength(_ length: Int) async throws {
    let script: @Sendable (Peer) async throws -> Void = { peer in
      try await peer.raw(Peer.shellPacket(1, Data(count: length)))
      try await peer.raw(Peer.shellPacket(3, Data([0])))
    }
    if length <= Self.packetLimit {
      let result = try await run(features: "shell_v2", service: "shell,v2,raw:x", script: script)
      #expect(result.stdout.count == length)
    } else {
      await #expect(throws: (any Error).self) {
        _ = try await run(features: "shell_v2", service: "shell,v2,raw:x", script: script)
      }
    }
  }

  @Test(arguments: [0, 1])
  func shellV2TotalOutputIsCapped(_ extra: Int) async throws {
    let script: @Sendable (Peer) async throws -> Void = { peer in
      let packet = Data(count: Self.packetLimit)
      for index in 0..<(Self.outputLimit / Self.packetLimit) {
        try await peer.raw(Peer.shellPacket(UInt8(1 + index % 2), packet))
      }
      if extra > 0 { try await peer.raw(Peer.shellPacket(1, Data(count: extra))) }
      try await peer.raw(Peer.shellPacket(3, Data([0])))
    }
    if extra == 0 {
      let result = try await run(features: "shell_v2", service: "shell,v2,raw:x", script: script)
      #expect(result.stdout.count + result.stderr.count == Self.outputLimit)
    } else {
      await #expect {
        _ = try await run(features: "shell_v2", service: "shell,v2,raw:x", script: script)
      } throws: {
        isViolation($0)
      }
    }
  }

  @Test(arguments: [0, 1])
  func legacyTotalOutputIsCapped(_ extra: Int) async throws {
    let trailer = Data("\n\(Self.token) 0\n".utf8)
    let script: @Sendable (Peer) async throws -> Void = { peer in
      try await peer.raw(Data(repeating: 0x61, count: Self.outputLimit - trailer.count + extra))
      try await peer.raw(trailer)
      await peer.finish()
    }
    let service = "shell:" + ADBShell.legacyWrapper("x", token: Self.token)
    if extra == 0 {
      let result = try await run(features: "", service: service, script: script)
      #expect(result.stdout.count == Self.outputLimit - trailer.count)
    } else {
      await #expect {
        _ = try await run(features: "", service: service, script: script)
      } throws: {
        isViolation($0)
      }
    }
  }

  // MARK: sync

  /// Serves `reply` after the request the test names, then reports whether the client hung up.
  private func session(
    features: Set<String>, hungUp: Latch,
    script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> (ADBSync, FakeADBServer) {
    try await SyncFixture.sync(features) { peer in
      try await script(peer)
      _ = try? await peer.stream.read(exactly: 1)
      hungUp.fire()
    }
  }

  private func expectFailureOrViolation(
    length: Int, hungUp: Latch, _ body: () async throws -> Void
  ) async throws {
    if length <= Self.packetLimit {
      await #expect(throws: ADBError.failed(String(repeating: "x", count: length))) {
        try await body()
      }
    } else {
      await #expect {
        try await body()
      } throws: {
        isViolation($0)
      }
      await hungUp.wait()
    }
  }

  @Test(arguments: [Self.packetLimit, Self.packetLimit + 1])
  func failMessageLengthInStat(_ length: Int) async throws {
    let hungUp = Latch()
    let (sync, server) = try await session(features: ["stat_v2"], hungUp: hungUp) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.fail(String(repeating: "x", count: length)))
    }
    defer { server.stop() }
    try await expectFailureOrViolation(length: length, hungUp: hungUp) {
      _ = try await sync.stat("/x")
    }
  }

  @Test(arguments: [Self.packetLimit, Self.packetLimit + 1])
  func failMessageLengthInList(_ length: Int) async throws {
    let hungUp = Latch()
    let (sync, server) = try await session(features: ["ls_v2"], hungUp: hungUp) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.fail(String(repeating: "x", count: length)))
    }
    defer { server.stop() }
    try await expectFailureOrViolation(length: length, hungUp: hungUp) {
      _ = try await sync.list("/x").entries
    }
  }

  @Test(arguments: [Self.packetLimit, Self.packetLimit + 1])
  func failMessageLengthInReceive(_ length: Int) async throws {
    let hungUp = Latch()
    let (sync, server) = try await session(features: [], hungUp: hungUp) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0o100600, size: 1, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.fail(String(repeating: "x", count: length)))
    }
    defer { server.stop() }
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try await expectFailureOrViolation(length: length, hungUp: hungUp) {
      _ = try await sync.receive("/x", to: handle) { _, _ in true }
    }
  }

  @Test(arguments: [Self.packetLimit, Self.packetLimit + 1])
  func failMessageLengthInSend(_ length: Int) async throws {
    let hungUp = Latch()
    let (sync, server) = try await session(features: [], hungUp: hungUp) { peer in
      let header = try await peer.syncHeader()
      _ = try await peer.stream.read(exactly: Int(header.length))
      while true {
        let next = try await peer.syncHeader()
        if next.id == "DONE" { break }
        _ = try await peer.stream.read(exactly: Int(next.length))
      }
      try await peer.raw(Peer.fail(String(repeating: "x", count: length)))
    }
    defer { server.stop() }
    let (url, handle) = try SyncFixture.scratchFile(Data(count: 10))
    defer { try? FileManager.default.removeItem(at: url) }
    try handle.seek(toOffset: 0)
    try await expectFailureOrViolation(length: length, hungUp: hungUp) {
      try await sync.send(handle, to: "/x", mode: 0o100644, mtime: .now) { _, _ in true }
    }
  }

  @Test(arguments: [Self.packetLimit, Self.packetLimit + 1])
  func dataChunkLength(_ length: Int) async throws {
    let hungUp = Latch()
    let (sync, server) = try await session(features: [], hungUp: hungUp) { peer in
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.stat(mode: 0o100600, size: 1, mtime: 1))
      _ = try await peer.syncPathRequest()
      try await peer.raw(Peer.data(Data(count: length)) + Peer.done())
    }
    defer { server.stop() }
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    if length <= Self.packetLimit {
      let written = try await sync.receive("/x", to: handle) { _, _ in true }
      #expect(written == UInt64(length))
    } else {
      await #expect {
        _ = try await sync.receive("/x", to: handle) { _, _ in true }
      } throws: {
        isViolation($0)
      }
      await hungUp.wait()
    }
  }

  @Test(arguments: [Self.nameLimit, Self.nameLimit + 1], [true, false])
  func entryNameLength(_ length: Int, extended: Bool) async throws {
    let hungUp = Latch()
    let name = String(repeating: "n", count: length)
    let features: Set<String> = extended ? ["ls_v2"] : []
    let (sync, server) = try await session(features: features, hungUp: hungUp) { peer in
      _ = try await peer.syncPathRequest()
      let entry =
        extended
        ? Peer.dnt2(name: name, mode: 0o100600, size: 1, mtime: 1)
        : Peer.dent(name: name, mode: 0o100600, size: 1, mtime: 1)
      try await peer.raw(entry + Peer.listDone(extended: extended))
    }
    defer { server.stop() }
    if length <= Self.nameLimit {
      let entries = try await sync.list("/x").entries
      #expect(entries.map(\.name) == [name])
    } else {
      await #expect {
        _ = try await sync.list("/x").entries
      } throws: {
        isViolation($0)
      }
      await hungUp.wait()
    }
  }
}
