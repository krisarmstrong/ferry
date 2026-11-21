import Foundation
import Testing

/// The agent's main.swift ends in `dispatchMain()`. A top-level `await` makes the whole file
/// an async main running as a block on the main queue, and `dispatchMain()` there traps ("BUG
/// IN CLIENT OF LIBDISPATCH: dispatch_main called from a block on the main queue"): the agent
/// would crash at every start, which no unit test runs.
struct AgentMainTests {
  @Test func theAgentsMainHasNoTopLevelAwait() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let main = try String(
      contentsOf: root.appending(path: "Apps/FerryAgent/main.swift"), encoding: .utf8)
    let lines = main.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(main.contains("\ndispatchMain()\n"))
    // Top-level statements are the unindented lines; closures and functions are indented.
    let topLevelAwaits = lines.filter { $0.first?.isWhitespace == false }.filter {
      $0.hasPrefix("await ") || $0.hasPrefix("try await ") || $0.contains(" = await ")
        || $0.contains(" = try await ")
    }
    #expect(topLevelAwaits.isEmpty, "\(topLevelAwaits)")
  }
}
