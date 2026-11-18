import Foundation
import Testing

@testable import ADBTransport

/// The legacy trailer, run through the Mac's real /bin/sh.
struct ADBLegacyShellTests {
  private static let token = "ferry-token-1"

  private func run(_ command: String) async throws -> ADBShellResult {
    let output = await ADBShellTests.sh(ADBShell.legacyWrapper(command, token: Self.token))
    return try ADBShell.parseLegacy(output, token: Self.token)
  }

  private func text(_ data: Data) -> String? { String(bytes: data, encoding: .utf8) }

  struct Example: Sendable {
    let command: String
    let status: Int32
    let stdout: String
  }

  @Test(arguments: [
    Example(command: "true", status: 0, stdout: ""),
    Example(command: "false", status: 1, stdout: ""),
    Example(command: "exit 3", status: 3, stdout: ""),
    Example(command: "printf abc", status: 0, stdout: "abc"),
    Example(command: #"printf 'a\nb\n'; exit 5"#, status: 5, stdout: "a\nb\n"),
    Example(command: #"printf 'x\n123'"#, status: 0, stdout: "x\n123"),
    Example(command: #"printf 'x\n123\n'; false"#, status: 1, stdout: "x\n123\n"),
    Example(command: "echo hi; (exit 9)", status: 9, stdout: "hi\n"),
    // A leading "(" must not turn the wrapper into an arithmetic command; a trailing comment
    // must not swallow the closing parenthesis.
    Example(command: "(exit 2)", status: 2, stdout: ""),
    Example(command: "(echo in; exit 4)", status: 4, stdout: "in\n"),
    Example(command: "false # trailing comment", status: 1, stdout: ""),
    Example(command: "echo kept # trailing comment", status: 0, stdout: "kept\n"),
    Example(
      command: #"printf 'ferry-token-1 7\nmore'"#, status: 0, stdout: "ferry-token-1 7\nmore"),
    Example(
      command: #"printf '\nferry-token-1 7\n'; exit 2"#, status: 2, stdout: "\nferry-token-1 7\n"),
  ])
  func statusAndOutputSurviveTheTrailer(_ example: Example) async throws {
    let result = try await run(example.command)
    #expect(result.status == example.status)
    #expect(text(result.stdout) == example.stdout)
    #expect(result.stderr.isEmpty)
  }

  @Test func theStatusLineMayEndInCarriageReturnFromAPty() throws {
    let result = try ADBShell.parseLegacy(
      Data("out\n\(Self.token) 4\r\n".utf8), token: Self.token)
    #expect(result.status == 4)
    #expect(text(result.stdout) == "out")
  }

  @Test(arguments: [
    "", "no newline", "only\n", "ferry-token-1 0\n", "out\nother-token 0\n",
    "out\nferry-token-1 x\n", "out\nferry-token-1 0",
  ])
  func malformedRepliesAreProtocolViolations(_ reply: String) {
    #expect {
      _ = try ADBShell.parseLegacy(Data(reply.utf8), token: Self.token)
    } throws: {
      if case .protocolViolation = $0 as? ADBError { return true }
      return false
    }
  }

  @Test func eachRunUsesItsOwnToken() {
    #expect(ADBShell.newToken() != ADBShell.newToken())
  }
}
