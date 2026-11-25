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

  /// The guides are rendered from help.json, the Spanish one with the catalog's Spanish, by
  /// scripts/user-guide.py (`make guide`): each committed file must be exactly what the script
  /// renders now.
  @Test(arguments: [("en", "docs/user-guide.md"), ("es", "docs/user-guide.es.md")])
  func theGuideIsWhatTheGeneratorRenders(language: String, path: String) async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [
      "python3", Self.root.appending(path: "scripts/user-guide.py").path, "--stdout", language,
    ]
    let output = Pipe()
    process.standardOutput = output
    // Read on a dispatch thread, not one of the shared pool's, which the other tests need.
    let rendered = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do {
          try process.run()
          let data = output.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(returning: data)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    #expect(process.terminationStatus == 0)
    let committed = try Data(contentsOf: Self.root.appending(path: path))
    #expect(rendered == committed, "\(path) is out of date: run make guide")
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

  /// The README and the user-facing docs name the testers by model only. The README's
  /// trademark notice is the one place the maker is named. (docs/spikes and docs/superpowers
  /// are engineering records, not copy.)
  @Test(arguments: ["README.md", "docs/TESTING.md", "docs/user-guide.md", "docs/user-guide.es.md"])
  func theDocsNameModelsOnly(path: String) throws {
    let notice = """
      NetAlly, LinkRunner, EtherScope and AirCheck are trademarks of NetAlly. Ferry is not \
      affiliated
      with or endorsed by NetAlly.
      """
    let text = try Self.text(path).replacing(notice, with: "")
      .replacing("Ask NetAlly to enable ADB on the tester.", with: "")
      .replacing("Pide a NetAlly que active ADB en el probador.", with: "")
    let lines = text.split(separator: "\n").filter { $0.contains("NetAlly") }
    #expect(lines.isEmpty, "\(path): \(lines)")
  }

  /// ferryctl's help, its string literals outside comments, names models only.
  @Test func ferryctlNamesModelsOnly() throws {
    let lines = try Self.text("Sources/ferryctl/Commands.swift").split(separator: "\n")
      .filter {
        $0.contains("NetAlly") && !$0.trimmingPrefix(while: \.isWhitespace).hasPrefix("//")
      }
    #expect(lines.isEmpty, "\(lines)")
  }
}
