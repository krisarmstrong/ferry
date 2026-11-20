import Foundation
import Testing

@testable import FerryUI

/// docs/user-guide.md carries the same help as the app: every heading and every string of
/// help.json, each message in its exact words. The README links to it.
struct UserGuideMirrorTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])

  private static func text(_ path: String) throws -> String {
    try String(contentsOf: root.appending(path: path), encoding: .utf8)
  }

  @Test func theGuideHasEveryHeading() throws {
    let lines = Set(try Self.text("docs/user-guide.md").split(separator: "\n").map(String.init))
    for category in Self.help.categories {
      #expect(lines.contains("## \(category.title)"), "\(category.title)")
      for topic in category.topics {
        #expect(lines.contains("### \(topic.title)"), "\(topic.title)")
        for group in topic.groups {
          #expect(lines.contains("#### \(group.title)"), "\(group.title)")
        }
      }
    }
  }

  @Test func theGuideHasEveryString() throws {
    let guide = try Self.text("docs/user-guide.md")
    for string in Self.help.topics.flatMap(\.strings) {
      #expect(guide.contains(string), "not in docs/user-guide.md: \(string)")
    }
  }

  /// The guide is rendered from help.json by scripts/user-guide.py (`make guide`): the
  /// committed file must be exactly what the script renders now.
  @Test func theGuideIsWhatTheGeneratorRenders() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [
      "python3", Self.root.appending(path: "scripts/user-guide.py").path, "--stdout",
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let rendered = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let committed = try Data(contentsOf: Self.root.appending(path: "docs/user-guide.md"))
    #expect(rendered == committed, "docs/user-guide.md is out of date: run make guide")
  }

  @Test func theReadmeLinksToTheGuide() throws {
    #expect(try Self.text("README.md").contains("](docs/user-guide.md)"))
  }

  /// Model names are facts; the maker's name is not used in headings or copy, except where
  /// the steps say to ask the maker to enable ADB.
  @Test func theMakersNameIsUsedOnlyWhereAllowed() throws {
    let allowed = "Ask NetAlly to enable ADB on the tester."
    let strings = Self.help.categories.map(\.title) + Self.help.topics.flatMap(\.strings)
    #expect(strings.filter { $0.contains("NetAlly") } == [allowed])
    let guide = try Self.text("docs/user-guide.md")
    #expect(guide.replacing(allowed, with: "").contains("NetAlly") == false)
  }
}
