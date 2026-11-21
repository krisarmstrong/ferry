import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Help")

/// Ferry's in-app help, decoded from `help.json` (see `Design/Help/README.md` for the schema):
/// short topics under category headings.
///
/// Every string in the file is a key in `Localizable.xcstrings`, looked up when shown, so the
/// help translates with the rest of the app. The connection steps use the same keys as
/// `GuideSteps`.
struct HelpContent: Decodable, Sendable, Equatable {
  let version: Int
  let categories: [HelpCategory]
  /// Each topic's words as search reads them, by topic id: built once, with the help.
  let searchIndex: [String: HelpSearchIndex]

  private enum CodingKeys: String, CodingKey {
    case version, categories
  }

  init(version: Int, categories: [HelpCategory]) {
    self.version = version
    self.categories = categories
    searchIndex = Dictionary(
      categories.flatMap(\.topics).map { ($0.id, HelpSearchIndex($0)) },
      uniquingKeysWith: { first, _ in first })
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decode(Int.self, forKey: .version),
      categories: try container.decode([HelpCategory].self, forKey: .categories))
  }

  /// The help that ships in the bundle, or `nil` if it is missing or does not decode. The tests
  /// check it, so that is a build defect, logged as a fault; the Help window then says help is
  /// not available rather than stopping Ferry.
  static let bundled: HelpContent? = load(
    Bundle.module.url(forResource: "help", withExtension: "json"))

  static func load(_ url: URL?) -> HelpContent? {
    guard let url else {
      log.fault("help.json is missing from the FerryUI bundle")
      return nil
    }
    do {
      return try JSONDecoder().decode(HelpContent.self, from: Data(contentsOf: url))
    } catch {
      log.fault("help.json does not load: \(error, privacy: .private)")
      return nil
    }
  }

  /// Every topic, in the order the sidebar lists them.
  var topics: [HelpTopic] { categories.flatMap(\.topics) }

  /// The categories with the topics that mention `query` in their title or any of their text,
  /// ignoring case, diacritics and Markdown; a category with none is left out. Every category
  /// for an empty query.
  func categories(matching query: String) -> [HelpCategory] {
    let query = HelpSearchIndex.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !query.isEmpty else { return categories }
    return categories.compactMap { category in
      let topics = category.topics.filter { searchIndex[$0.id]?.contains(query) == true }
      return topics.isEmpty ? nil : HelpCategory(title: category.title, topics: topics)
    }
  }

  /// The topic that explains the message whose catalog key is `key`.
  func topic(forMessage key: String) -> HelpTopic? {
    topics.first { topic in topic.messages.contains { $0.message == key } }
  }
}

/// A topic's words as the reader sees them, without Markdown, folded for search.
struct HelpSearchIndex: Sendable, Equatable {
  let title: String
  /// Every string the topic shows, its title among them.
  let text: [String]

  init(_ topic: HelpTopic) {
    title = Self.folded(HelpText.plain(topic.title))
    text = topic.strings.map { Self.folded(HelpText.plain($0)) }
  }

  /// `string` ignoring case, diacritics and width, as search compares it.
  static func folded(_ string: String) -> String {
    string.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
  }

  /// Whether the topic mentions `query`, already folded.
  func contains(_ query: String) -> Bool {
    text.contains { $0.contains(query) }
  }
}

/// A heading in the sidebar and the topics under it.
struct HelpCategory: Decodable, Sendable, Hashable {
  let title: String
  let topics: [HelpTopic]
}

/// One sidebar entry: a title and symbol, its own blocks, titled groups of blocks, then the
/// messages it explains.
struct HelpTopic: Decodable, Sendable, Identifiable, Hashable {
  let id: String
  let title: String
  /// An SF Symbol name.
  let symbol: String
  let body: HelpBody
  let groups: [HelpGroup]
  let messages: [HelpMessage]

  private enum CodingKeys: String, CodingKey {
    case id, title, symbol, groups, messages
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    symbol = try container.decode(String.self, forKey: .symbol)
    groups = try container.decodeIfPresent([HelpGroup].self, forKey: .groups) ?? []
    messages = try container.decodeIfPresent([HelpMessage].self, forKey: .messages) ?? []
    body = try HelpBody(from: decoder)
  }

  /// Every string the topic shows, as catalog keys.
  var strings: [String] {
    [title] + body.strings + groups.flatMap { [$0.title] + $0.body.strings }
      + messages.flatMap(\.strings)
  }
}

struct HelpGroup: Decodable, Sendable, Hashable {
  let title: String
  let body: HelpBody

  private enum CodingKeys: String, CodingKey {
    case title
  }

  init(from decoder: any Decoder) throws {
    title = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .title)
    body = try HelpBody(from: decoder)
  }
}

/// A message Ferry shows, in its exact words, with why it appears and what to do.
struct HelpMessage: Decodable, Sendable, Hashable {
  /// The message's key in the String Catalog of the module that shows it, as the code writes
  /// it: the menu's Help links name a message by this key.
  let message: String
  let cause: String
  let fix: String

  /// The message as the reader sees it, each value it is shown with as "…": a key in FerryUI's
  /// catalog.
  var wording: String { Self.wording(of: message) }

  /// A message key as the reader sees it, each value as "…".
  static func wording(of key: String) -> String {
    key.replacing(/%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u)/, with: "…").replacing("%%", with: "%")
  }

  var strings: [String] { [wording, cause, fix] }
}

/// The blocks a topic or group can hold, shown in this order.
struct HelpBody: Decodable, Sendable, Hashable {
  let paragraphs: [String]
  let steps: [String]
  let definitions: [HelpDefinition]
  let note: String?
  let link: HelpLink?
  let action: HelpAction?

  private enum CodingKeys: String, CodingKey {
    case paragraphs, steps, definitions, note, link, action
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    paragraphs = try container.decodeIfPresent([String].self, forKey: .paragraphs) ?? []
    steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
    definitions = try container.decodeIfPresent([HelpDefinition].self, forKey: .definitions) ?? []
    note = try container.decodeIfPresent(String.self, forKey: .note)
    link = try container.decodeIfPresent(HelpLink.self, forKey: .link)
    action = try container.decodeIfPresent(HelpAction.self, forKey: .action)
  }

  var strings: [String] {
    paragraphs + steps + definitions.flatMap { [$0.term, $0.detail] }
      + [note, link?.title]
      .compactMap(\.self)
  }
}

struct HelpDefinition: Decodable, Sendable, Hashable {
  let term: String
  let detail: String
}

/// Something Help does itself, as a button at the end of the block.
enum HelpAction: String, Decodable, Sendable {
  /// Remove Ferry…, after a confirmation.
  case removeFerry
}

/// A button that opens the setup guide: with the model picker, or with one family's steps, on
/// file transfer or USB debugging.
struct HelpLink: Decodable, Sendable, Hashable {
  let title: String
  /// The family the guide opens on; `nil` shows the model picker.
  let family: DeviceFamily?
  let topic: GuideTopic

  private enum CodingKeys: String, CodingKey {
    case title, target
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    let target = try container.decode(String.self, forKey: .target)
    for topic in GuideTopic.allCases {
      let (word, name) = Self.targetPrefix(of: topic)
      if target == word {
        family = nil
        self.topic = topic
        return
      }
      if target.hasPrefix(name) {
        guard let family = DeviceFamily(rawValue: String(target.dropFirst(name.count))) else {
          break
        }
        self.family = family
        self.topic = topic
        return
      }
    }
    throw DecodingError.dataCorruptedError(
      forKey: .target, in: container, debugDescription: "unknown link target \(target)")
  }

  /// The target word that opens the guide on `topic` with the model picker, and the prefix that
  /// names a family.
  private static func targetPrefix(of topic: GuideTopic) -> (word: String, family: String) {
    switch topic {
    case .fileTransfer: ("guide", "guide:")
    case .usbDebugging: ("debugging", "debugging:")
    }
  }
}

/// Help strings are catalog keys with inline Markdown.
enum HelpText {
  static func resource(_ key: String) -> LocalizedStringResource {
    LocalizedStringResource(String.LocalizationValue(key), bundle: .module)
  }

  /// The localized text with its Markdown applied.
  static func attributed(_ key: String) -> AttributedString {
    AttributedString(localized: resource(key))
  }

  /// The localized text without Markdown, as the reader sees it: what search matches.
  static func plain(_ key: String) -> String {
    String(attributed(key).characters)
  }
}
