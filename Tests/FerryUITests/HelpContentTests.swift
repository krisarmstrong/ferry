import AppKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryUI

struct HelpContentTests {
  private static let help =
    HelpContent.bundled ?? HelpContent(version: 0, categories: [])

  private static func topic(_ id: String) throws -> HelpTopic {
    try #require(help.topics.first { $0.id == id })
  }

  private static func decode(_ json: String) throws -> HelpContent {
    try JSONDecoder().decode(HelpContent.self, from: Data(json.utf8))
  }

  @Test func bundledHelpDecodes() {
    #expect(HelpContent.bundled != nil)
    #expect(Self.help.version == 2)
    #expect(Self.help.topics.first?.id == "getting-started")
    #expect(Set(Self.help.topics.map(\.id)).count == Self.help.topics.count)
    #expect(Self.help.categories.allSatisfy { !$0.topics.isEmpty })
    // Each topic shows something besides its title.
    #expect(Self.help.topics.allSatisfy { $0.strings.count > 1 })
    // What is planned belongs in the user guide, not in the app's help.
    #expect(!Self.help.topics.contains { $0.id == "coming-next" })
  }

  /// Within a topic, group titles, terms, paragraphs and messages are unique, so no two rows
  /// are mistaken for one another, and a message is explained in one topic only.
  @Test func entriesAreUniqueWithinTheirTopic() {
    func unique(_ values: [String]) -> Bool { Set(values).count == values.count }
    for topic in Self.help.topics {
      #expect(unique(topic.groups.map(\.title)), "\(topic.id)")
      for body in [topic.body] + topic.groups.map(\.body) {
        #expect(unique(body.paragraphs), "\(topic.id)")
        #expect(unique(body.definitions.map(\.term)), "\(topic.id)")
      }
    }
    #expect(unique(Self.help.topics.flatMap(\.messages).map(\.message)))
  }

  @Test func everySymbolExists() {
    for topic in Self.help.topics {
      #expect(
        NSImage(systemSymbolName: topic.symbol, accessibilityDescription: nil) != nil,
        "\(topic.id): \(topic.symbol)")
    }
  }

  /// A message reads as its key with each value shown as "…".
  @Test(arguments: [
    ("The device was disconnected.", "The device was disconnected."),
    ("adb: %@", "adb: …"),
    ("Sent %lld of %lld to %@", "Sent … of … to …"),
    (
      "The device sent %llu bytes of a file it lists as %llu bytes.",
      "The device sent … bytes of a file it lists as … bytes."
    ),
  ])
  func aMessageReadsWithItsValuesElided(key: String, wording: String) throws {
    let json = """
      {"version": 2, "categories": [{"title": "C", "topics": [
        {"id": "a", "title": "A", "symbol": "folder",
         "messages": [{"message": "\(key)", "cause": "C", "fix": "F"}]}
      ]}]}
      """
    let message = try #require(try Self.decode(json).topics.first?.messages.first)
    #expect(message.wording == wording)
    #expect(message.strings == [wording, "C", "F"])
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
    for key in Self.help.categories.map(\.title) + Self.help.topics.flatMap(\.strings) {
      #expect(keys[key] != nil, "not in Localizable.xcstrings: \(key)")
    }
  }

  @Test func connectionStepsMatchTheSetupGuide() throws {
    func keys(_ family: DeviceFamily) -> [String] {
      GuideSteps.steps(for: family).map(\.key)
    }
    let netAlly = try Self.topic("connect-tester")
    #expect(netAlly.body.steps == keys(.netAllyAndroid8Board))
    #expect(netAlly.body.link?.family == .netAllyAndroid8Board)
    let android = try Self.topic("connect-android")
    #expect(
      android.groups.map(\.body.steps) == [keys(.otherAndroid8to9), keys(.otherAndroid10Plus)])
  }

  @Test func debuggingStepsMatchTheSetupGuide() throws {
    func keys(_ family: DeviceFamily) -> [String] {
      GuideSteps.steps(for: family, topic: .usbDebugging).map(\.key)
    }
    let section = try Self.topic("usb-debugging")
    let groups = Dictionary(uniqueKeysWithValues: section.groups.map { ($0.title, $0.body) })
    #expect(
      groups[DeviceFamily.netAllyAndroid8Board.title.key]?.steps
        == keys(.netAllyAndroid8Board))
    #expect(groups["Android 8 or 9"]?.steps == keys(.otherAndroid8to9))
    #expect(groups["Android 10 or newer"]?.steps == keys(.otherAndroid10Plus))
    for group in section.groups { #expect(group.body.note == GuideSteps.debuggingNote.key) }
    #expect(section.body.link?.topic == .usbDebugging)
    #expect(section.body.link?.family == nil)
  }

  /// One category of `topics` (JSON objects), as a help.json would hold them.
  private static func wrapped(_ topics: String) -> String {
    """
    {"version": 2, "categories": [{"title": "C", "topics": [\(topics)]}]}
    """
  }

  @Test func linkTargetsDecode() throws {
    let json = Self.wrapped(
      """
      {"id": "a", "title": "A", "symbol": "folder", "link": {"title": "L", "target": "guide"}},
      {"id": "b", "title": "B", "symbol": "folder",
       "link": {"title": "L", "target": "guide:otherAndroid10Plus"}}
      """)
    let topics = try Self.decode(json).topics
    #expect(topics[0].body.link?.family == nil)
    #expect(topics[0].body.link?.topic == .fileTransfer)
    #expect(topics[1].body.link?.family == .otherAndroid10Plus)
    #expect(topics[1].body.link?.topic == .fileTransfer)
    #expect(topics[0].groups.isEmpty)
    #expect(topics[0].messages.isEmpty)
    #expect(topics[0].body.steps.isEmpty)
  }

  @Test func debuggingLinkTargetsDecode() throws {
    let json = Self.wrapped(
      """
      {"id": "a", "title": "A", "symbol": "folder", "link": {"title": "L", "target": "debugging"}},
      {"id": "b", "title": "B", "symbol": "folder",
       "link": {"title": "L", "target": "debugging:netAllyAndroid8Board"}}
      """)
    let topics = try Self.decode(json).topics
    #expect(topics[0].body.link?.family == nil)
    #expect(topics[0].body.link?.topic == .usbDebugging)
    #expect(topics[1].body.link?.family == .netAllyAndroid8Board)
    #expect(topics[1].body.link?.topic == .usbDebugging)
  }

  @Test(arguments: ["guide:aircheckG3", "web", "guide:", "debugging:", "debugging:aircheckG3"])
  func unknownLinkTargetIsRejected(target: String) {
    let json = Self.wrapped(
      """
      {"id": "a", "title": "A", "symbol": "folder", "link": {"title": "L", "target": "\(target)"}}
      """)
    #expect(throws: DecodingError.self) { try Self.decode(json) }
  }

  /// Remove Ferry… lives in Help, under Troubleshooting, and nowhere else.
  @Test func removeFerryIsUnderTroubleshooting() throws {
    let troubleshooting = try #require(
      Self.help.categories.first { $0.title == "Troubleshooting" })
    let topic = try #require(troubleshooting.topics.first { $0.body.action == .removeFerry })
    #expect(topic.title == "Remove Ferry")
    let others = Self.help.topics.flatMap { [$0.body] + $0.groups.map(\.body) }
      .filter { $0.action == .removeFerry }
    #expect(others.count == 1)
    // Nothing in Help sends the reader to a Settings window that no longer exists.
    #expect(
      !Self.help.topics.contains { topic in
        topic.strings.contains { $0.contains("Settings…") || $0.contains("Ferry's Settings") }
      })
  }

  /// Show Welcome Window is on What Ferry does, the first topic, and nowhere else.
  @Test func showWelcomeIsOnTheFirstTopic() throws {
    let bodies = Self.help.topics.flatMap { [$0.body] + $0.groups.map(\.body) }
    #expect(bodies.filter { $0.action == .showWelcome }.count == 1)
    #expect(Self.help.topics.first?.body.action == .showWelcome)
  }

  @Test func anUnknownActionIsRejected() {
    let json = Self.wrapped(
      """
      {"id": "a", "title": "A", "symbol": "folder", "action": "reboot"}
      """)
    #expect(throws: DecodingError.self) { try Self.decode(json) }
  }

  /// A missing or broken help.json must not stop Ferry: the Help window says help is not
  /// available instead.
  @Test func missingOrBrokenHelpLoadsNothing() throws {
    #expect(HelpContent.load(nil) == nil)
    let broken = TestScratch.root.appending(path: "help-\(UUID()).json")
    try Data("{".utf8).write(to: broken)
    defer { try? FileManager.default.removeItem(at: broken) }
    #expect(HelpContent.load(broken) == nil)
  }
}
