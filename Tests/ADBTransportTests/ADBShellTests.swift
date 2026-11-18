import Foundation
import Testing

@testable import ADBTransport

struct ADBShellTests {
  /// What the Mac's own /bin/sh makes of `script`. The script goes in on stdin, byte for byte:
  /// `Process.arguments` would canonically reorder combining marks and change the bytes.
  static func sh(_ script: String) async -> Data {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    // Waiting by callback keeps the cooperative threads free for the other tests.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in done.resume() }
      do {
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
      } catch {
        process.terminationHandler = nil
        done.resume()
      }
    }
    return output.fileHandleForReading.readDataToEndOfFile()
  }

  /// `printf %s <quoted>`: the bytes out must be the bytes in, and nothing else.
  private func shellEcho(_ argument: String) async throws -> Data {
    await Self.sh("printf %s " + (try ADBShell.quote(argument)))
  }

  @Test(
    arguments: [
      "plain", "it's", "$HOME", "`id`", "back\\slash", "line\nbreak", "-n", "--", "-rf /",
      "emoji \u{1F600}", "", "a b", "*", "; rm -rf /", "tab\there", "\"quoted\"",
      // A quote followed by a combining mark is one Character but still a raw quote byte.
      "a'\u{301}; echo PWNED; '", "'\u{200D}; echo PWNED; '", "'\u{FE0F}; echo PWNED; '",
    ])
  func quoteRoundTripsThroughRealShell(_ argument: String) async throws {
    #expect(try await shellEcho(argument) == Data(argument.utf8))
  }

  @Test func commandQuotesEveryArgumentAndLeavesTheProgram() throws {
    #expect(try ADBShell.command("rm", ["-f", "a b", "it's"]) == "rm '-f' 'a b' 'it'\\''s'")
    #expect(try ADBShell.command("ls", []) == "ls")
  }

  @Test func aNulByteIsRefusedBecauseTheDeviceShellWouldTruncateThere() {
    let hostile = "/sdcard/a\0/../../etc"
    #expect(throws: ADBError.invalidArgument(hostile)) { try ADBShell.quote(hostile) }
    #expect(throws: ADBError.invalidArgument(hostile)) {
      try ADBShell.command("rm", ["-f", "fine", hostile])
    }
  }

  /// Scalars that glue onto a neighbour in a grapheme cluster, and line breaks.
  private static let gluing: [String] = [
    "\u{301}", "\u{300}", "\u{338}", "\u{200D}", "\u{200C}", "\u{FE0F}", "\u{FE0E}",
    "\u{1F3FB}", "\u{20E3}", "\u{1161}", "\u{0E31}", "\u{1F468}\u{200D}\u{1F469}", "\r", "\n",
    "\r\n", "\u{E0020}", "'",
  ]

  @Test func quoteSurvivesEveryQuoteAndGluingScalarPairing() async throws {
    var cases: [String] = []
    for first in Self.gluing {
      cases += ["a'" + first, first + "'", "'" + first + "'", "a" + first + "'" + first]
      for second in Self.gluing {
        cases.append("'" + first + second + "'" + first)
      }
    }
    for argument in cases {
      let echoed = try await shellEcho(argument)
      #expect(echoed == Data(argument.utf8), "\(Array(argument.unicodeScalars))")
    }
  }
}
