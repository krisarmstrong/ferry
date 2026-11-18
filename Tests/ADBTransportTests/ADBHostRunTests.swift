import Foundation
import Testing

@testable import ADBTransport

struct ADBHostRunTests {
  typealias Peer = FakeADBServer.Peer

  /// Serves `host-serial:<s>:features` on one connection and the shell service on the next.
  private func server(
    features: String, service: String, shell: @escaping @Sendable (Peer) async throws -> Void
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
      try await shell(peer)
    }
  }

  private func host(_ server: FakeADBServer) -> ADBHost {
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
    let result = try await host(server).run(serial: "S", command: "ls /x")
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
      _ = try await host(server).run(serial: "S", command: "x")
    }
  }

  @Test func withoutShellV2TheStatusRidesOnTheLastLine() async throws {
    let server = try await server(
      features: "cmd", service: "shell:ls /x; echo; echo $?"
    ) { peer in
      try await peer.send("a\nb\n\n3\n")
    }
    defer { server.stop() }
    let result = try await host(server).run(serial: "S", command: "ls /x")
    #expect(result.status == 3)
    #expect(String(bytes: result.stdout, encoding: .utf8) == "a\nb\n")
    #expect(result.stderr.isEmpty)
  }

  @Test func legacyOutputWithoutTrailingNewlineKeepsItsBytes() async throws {
    let service = "shell:printf abc; echo; echo $?"
    let server = try await server(features: "", service: service) { peer in
      try await peer.send("abc\n0\n")
    }
    defer { server.stop() }
    let result = try await host(server).run(serial: "S", command: "printf abc")
    #expect(result.status == 0)
    #expect(String(bytes: result.stdout, encoding: .utf8) == "abc")
  }

  @Test func legacyReplyWithoutAStatusLineIsAProtocolViolation() async throws {
    let server = try await server(features: "", service: "shell:x; echo; echo $?") { peer in
      try await peer.send("")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.self) {
      _ = try await host(server).run(serial: "S", command: "x")
    }
  }
}
