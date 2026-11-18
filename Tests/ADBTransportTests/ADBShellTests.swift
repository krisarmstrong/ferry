import Foundation
import Testing

@testable import ADBTransport

struct ADBShellTests {
  /// Runs `printf %s <quoted>` in the Mac's own /bin/sh, with the script as one argument.
  private func shellEcho(_ argument: String) async throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", "printf %s " + ADBShell.quote(argument)]
    let output = Pipe()
    process.standardOutput = output
    // Waiting by callback keeps the cooperative threads free for the other tests.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in done.resume() }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        done.resume()
      }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return try #require(String(bytes: data, encoding: .utf8))
  }

  @Test(
    arguments: [
      "plain", "it's", "$HOME", "`id`", "back\\slash", "line\nbreak", "-n", "--", "-rf /",
      "emoji \u{1F600}", "", "a b", "*", "; rm -rf /", "tab\there", "\"quoted\"",
    ])
  func quoteRoundTripsThroughRealShell(_ argument: String) async throws {
    #expect(try await shellEcho(argument) == argument)
  }

  @Test func commandQuotesEveryArgumentAndLeavesTheProgram() {
    #expect(ADBShell.command("rm", ["-f", "a b", "it's"]) == "rm '-f' 'a b' 'it'\\''s'")
    #expect(ADBShell.command("ls", []) == "ls")
  }
}
