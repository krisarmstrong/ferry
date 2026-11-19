import Foundation
import Testing

@testable import ADBTransport

struct ADBHostRunTests {
  typealias Peer = FakeADBServer.Peer

  /// Serves `host-serial:<s>:features` on one connection and the shell service on the next.
  func server(
    features: String, service: String, stdin: Box<Data>? = nil,
    shell: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> FakeADBServer {
    try await FakeADBServer.start { peer in
      let first = try await peer.request()
      if first.hasPrefix("host-serial:") {
        try await peer.answer(features)
        return
      }
      try await peer.okay()
      let started = try await peer.request()
      guard started == service else { throw ScriptError.unexpected(started) }
      try await peer.okay()
      if service.hasPrefix("shell,v2") {
        // The client closes stdin first; a server that exits with that unread resets the socket.
        await stdin?.set(try await peer.stream.read(exactly: 5))
        if stdin == nil { _ = try await peer.stream.read(exactly: 5) }
      }
      try await shell(peer)
    }
  }

  func host(_ server: FakeADBServer) -> ADBHost {
    ADBHost(port: server.port, locator: ADBHostTests.noAdb)
  }

  @Test func shellV2SeparatesStdoutStderrAndStatus() async throws {
    let server = try await server(
      features: "cmd,shell_v2,stat_v2", service: "shell,v2,raw:ls /x"
    ) { peer in
      try await peer.raw(Peer.shellPacket(1, Data("out1".utf8)))
      try await peer.raw(Peer.shellPacket(2, Data("err".utf8)))
      try await peer.raw(Peer.shellPacket(1, Data("out2".utf8)))
      try await peer.raw(Peer.shellPacket(3, Data([7])))
    }
    defer { server.stop() }
    let result = try await host(server).run(serial: "S", command: "ls /x", transportID: nil)
    #expect(result.status == 7)
    #expect(String(bytes: result.stdout, encoding: .utf8) == "out1out2")
    #expect(String(bytes: result.stderr, encoding: .utf8) == "err")
  }

  @Test func shellV2ClosingBeforeTheExitPacketIsAnError() async throws {
    let server = try await server(features: "shell_v2", service: "shell,v2,raw:x") { peer in
      try await peer.raw(Peer.shellPacket(1, Data("partial".utf8)))
    }
    defer { server.stop() }
    await #expect(throws: ADBError.connectionClosed) {
      _ = try await host(server).run(serial: "S", command: "x", transportID: nil)
    }
  }

  private static let token = "ferry-test-token"

  private func legacyService(_ command: String) -> String {
    "shell:" + ADBShell.legacyWrapper(command, token: Self.token)
  }

  @Test func withoutShellV2TheStatusRidesOnTheLastLine() async throws {
    let server = try await server(features: "cmd", service: legacyService("ls /x")) { peer in
      try await peer.send("a\nb\n\n\(Self.token) 3\n")
    }
    defer { server.stop() }
    let result = try await host(server).run(
      serial: "S", command: "ls /x", token: Self.token, transportID: nil)
    #expect(result.status == 3)
    #expect(String(bytes: result.stdout, encoding: .utf8) == "a\nb\n")
    #expect(result.stderr.isEmpty)
  }

  @Test func legacyReplyWithoutTheSentinelIsAProtocolViolation() async throws {
    // A drop mid-output whose last line is a number must not read as a status.
    let server = try await server(features: "", service: legacyService("x")) { peer in
      try await peer.send("partial\n0\n")
    }
    defer { server.stop() }
    await #expect {
      _ = try await host(server).run(serial: "S", command: "x", token: Self.token, transportID: nil)
    } throws: {
      if case .protocolViolation = $0 as? ADBError { return true }
      return false
    }
  }

  @Test func shellV2ClosesStdinSoACommandThatReadsItCannotHang() async throws {
    let first = Box(Data())
    let server = try await server(
      features: "shell_v2", service: "shell,v2,raw:cat", stdin: first
    ) { peer in
      try await peer.raw(Peer.shellPacket(3, Data([0])))
    }
    defer { server.stop() }
    _ = try await host(server).run(serial: "S", command: "cat", transportID: nil)
    #expect(await first.value == Data([4, 0, 0, 0, 0]))
  }
}
