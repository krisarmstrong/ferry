import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Help")

/// Ferry's in-app help, decoded from `help.json` (see `Design/Help/README.md` for the schema).
///
/// Every string in the file is a key in `Localizable.xcstrings`, looked up when shown, so the
/// help translates with the rest of the app. The connection steps use the same keys as
/// `GuideSteps`.
struct HelpContent: Decodable, Sendable, Equatable {
  let version: Int
  let sections: [HelpSection]

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
      log.fault("help.json does not load: \(error, privacy: .public)")
      return nil
    }
  }

  /// The section the window shows, in the sidebar and the detail alike: the selected one if the
  /// search shows it, else the first the search shows. `nil` when the search shows none.
  func shownSection(selection: String, query: String) -> HelpSection? {
    let shown = sections(matching: query)
    return shown.first { $0.id == selection } ?? shown.first
  }

  /// The sections that mention `query` in their title or any of their text, ignoring case,
  /// diacritics and Markdown. Every section for an empty query.
  func sections(matching query: String) -> [HelpSection] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return sections }
    return sections.filter { section in
      section.strings.contains { HelpText.plain($0).localizedStandardContains(query) }
    }
  }
}

/// One sidebar entry: a title and symbol, its own blocks, then titled groups of blocks.
struct HelpSection: Decodable, Sendable, Identifiable, Hashable {
  let id: String
  let title: String
  /// An SF Symbol name.
  let symbol: String
  let body: HelpBody
  let groups: [HelpGroup]

  private enum CodingKeys: String, CodingKey {
    case id, title, symbol, groups
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    symbol = try container.decode(String.self, forKey: .symbol)
    groups = try container.decodeIfPresent([HelpGroup].self, forKey: .groups) ?? []
    body = try HelpBody(from: decoder)
  }

  /// Every string the section shows, as catalog keys.
  var strings: [String] {
    [title] + body.strings + groups.flatMap { [$0.title] + $0.body.strings }
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

/// The blocks a section or group can hold, shown in this order.
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
