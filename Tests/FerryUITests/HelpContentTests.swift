import AppKit
import Foundation
import Testing

@testable import FerryUI

struct HelpContentTests {
  private static let help =
    HelpContent.bundled ?? HelpContent(version: 0, title: "", sections: [])

  private static func section(_ id: String) throws -> HelpSection {
    try #require(help.sections.first { $0.id == id })
  }

  private static func decode(_ json: String) throws -> HelpContent {
    try JSONDecoder().decode(HelpContent.self, from: Data(json.utf8))
  }

  @Test func bundledHelpDecodes() {
    #expect(HelpContent.bundled != nil)
    #expect(Self.help.version == 1)
    #expect(Self.help.sections.first?.id == "getting-started")
    #expect(Set(Self.help.sections.map(\.id)).count == Self.help.sections.count)
    #expect(Self.help.sections.allSatisfy { !$0.strings.isEmpty })
  }

  @Test func everySymbolExists() {
    for section in Self.help.sections {
      #expect(
        NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) != nil,
        "\(section.id): \(section.symbol)")
    }
  }

  /// The help is looked up in the catalog at run time, so a string missing from it would not
  /// be translated.
  @Test func everyStringIsInTheCatalog() throws {
    let catalogURL = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/FerryUI/Localizable.xcstrings")
    struct Catalog: Decodable { let strings: [String: AnyCodable] }
    struct AnyCodable: Decodable {}
    let keys = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL)).strings
    for key in Self.help.sections.flatMap(\.strings) {
      #expect(keys[key] != nil, "not in Localizable.xcstrings: \(key)")
    }
  }

  @Test func connectionStepsMatchTheSetupGuide() throws {
    func keys(_ family: DeviceFamily) -> [String] {
      GuideSteps.steps(for: family).map(\.key)
    }
    let netAlly = try Self.section("connect-netally")
    #expect(netAlly.body.steps == keys(.netAllyAndroid8Board))
    #expect(netAlly.body.link?.family == .netAllyAndroid8Board)
    let android = try Self.section("connect-android")
    #expect(
      android.groups.map(\.body.steps) == [keys(.otherAndroid8to9), keys(.otherAndroid10Plus)])
  }

  @Test func linkTargetsDecode() throws {
    let json = """
      {"version": 1, "title": "T", "sections": [
        {"id": "a", "title": "A", "symbol": "folder", "link": {"title": "L", "target": "guide"}},
        {"id": "b", "title": "B", "symbol": "folder",
         "link": {"title": "L", "target": "guide:otherAndroid10Plus"}}
      ]}
      """
    let sections = try Self.decode(json).sections
    #expect(sections[0].body.link?.family == nil)
    #expect(sections[1].body.link?.family == .otherAndroid10Plus)
    #expect(sections[0].groups.isEmpty)
    #expect(sections[0].body.steps.isEmpty)
  }

  @Test(arguments: ["guide:aircheckG3", "web", "guide:"])
  func unknownLinkTargetIsRejected(target: String) {
    let json = """
      {"version": 1, "title": "T", "sections": [
        {"id": "a", "title": "A", "symbol": "folder", "link": {"title": "L", "target": "\(target)"}}
      ]}
      """
    #expect(throws: DecodingError.self) { try Self.decode(json) }
  }

  @Test(arguments: ["", "   "])
  func emptySearchShowsEverySection(query: String) {
    #expect(Self.help.sections(matching: query) == Self.help.sections)
  }

  @Test func searchMatchesTitlesAndText() {
    #expect(Self.help.sections(matching: "privacy").map(\.id) == ["privacy"])
    #expect(Self.help.sections(matching: "TELEMETRY").map(\.id) == ["privacy"])
    #expect(Self.help.sections(matching: "MacDroid").map(\.id) == ["troubleshooting"])
  }

  /// "Tap **Transfer files**" reads "Tap Transfer files", so a search for that finds it.
  @Test func searchIgnoresMarkdown() {
    let ids = Self.help.sections(matching: "tap transfer files").map(\.id)
    #expect(ids.contains("connect-netally"))
    #expect(ids.contains("connect-android"))
  }

  @Test func searchIgnoresDiacritics() {
    #expect(Self.help.sections(matching: "Chécking").map(\.id) == ["menu"])
  }

  @Test func searchWithNoMatchIsEmpty() {
    #expect(Self.help.sections(matching: "zzqx").isEmpty)
  }

  /// A missing or broken help.json must not stop Ferry: the Help window says help is not
  /// available instead.
  @Test func missingOrBrokenHelpLoadsNothing() throws {
    #expect(HelpContent.load(nil) == nil)
    let broken = FileManager.default.temporaryDirectory.appending(path: "help-\(UUID()).json")
    try Data("{".utf8).write(to: broken)
    defer { try? FileManager.default.removeItem(at: broken) }
    #expect(HelpContent.load(broken) == nil)
  }
}
