import Foundation
import Testing

@testable import FerryUI

/// Ferry ships in English and Spanish. Every key of every String Catalog has a Spanish
/// translation that keeps the English's values, and the compiled bundles answer in Spanish:
/// Help, the counted messages in both their forms, and the capture file names. The agent's and
/// the FileProvider extension's tests check their own Spanish.
struct SpanishLocalizationTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// Every String Catalog: one per module, and the app's usage descriptions.
  static let catalogs = [
    "Sources/FerryUI/Localizable.xcstrings", "Sources/FerryText/Localizable.xcstrings",
    "Sources/FerryAgentCore/Localizable.xcstrings",
    "Sources/FerryProviderCore/Localizable.xcstrings",
    "Sources/FerrySyncCore/Localizable.xcstrings", "Apps/Ferry/InfoPlist.xcstrings",
  ]

  private struct StringUnit: Decodable {
    let state: String
    let value: String
  }

  private struct Plural: Decodable {
    let one: Localization?
    let other: Localization
  }

  private struct Variations: Decodable {
    let plural: Plural
  }

  private struct Substitution: Decodable {
    let argNum: Int
    let formatSpecifier: String
    let variations: Variations
  }

  private final class Localization: Decodable {
    let stringUnit: StringUnit?
    let substitutions: [String: Substitution]?
  }

  private struct Entry: Decodable {
    let localizations: [String: Localization]?
  }

  private struct Catalog: Decodable {
    let strings: [String: Entry]
  }

  private static func catalog(_ path: String) throws -> Catalog {
    try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root.appending(path: path)))
  }

  /// The values a string is shown with, by kind and count, whatever their order. A plural's
  /// `%#@name@` counts as the value it stands for, and each form must keep the others' values.
  private static func values(_ text: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for match in text.replacing("%%", with: "").matches(of: /%(?:\d+\$)?(@|lld|llu|ld|lu|d|u)/) {
      counts[String(match.output.1), default: 0] += 1
    }
    return counts
  }

  /// A localization written out in its `one` or `other` form, `%arg` and `%#@name@` replaced by
  /// their specifiers; nil if it has no value.
  private static func written(_ localization: Localization, one: Bool = false) -> String? {
    guard var text = localization.stringUnit?.value else { return nil }
    for (name, substitution) in localization.substitutions ?? [:] {
      let plural = substitution.variations.plural
      let chosen = one ? plural.one ?? plural.other : plural.other
      let value = (chosen.stringUnit?.value ?? "")
        .replacing("%arg", with: "%" + substitution.formatSpecifier)
      text = text.replacing("%#@\(name)@", with: value)
    }
    return text
  }

  @Test(arguments: catalogs)
  func everyKeyHasSpanishWithTheEnglishValues(catalog: String) throws {
    var missing: [String] = []
    var changed: [String] = []
    for (key, entry) in try Self.catalog(catalog).strings {
      guard let spanish = entry.localizations?["es"], spanish.stringUnit?.state == "translated",
        let other = Self.written(spanish), !other.isEmpty
      else {
        missing.append(key)
        continue
      }
      let english = entry.localizations?["en"].flatMap { Self.written($0) } ?? key
      let one = Self.written(spanish, one: true) ?? other
      for (form, text) in [("other", other), ("one", one)]
      where Self.values(text) != Self.values(english) {
        changed.append("\(key) (\(form)): \(text)")
      }
    }
    #expect(missing.isEmpty, "\(catalog) keys without Spanish: \(missing.sorted())")
    #expect(changed.isEmpty, "\(catalog) Spanish that drops or adds a value: \(changed.sorted())")
  }

  // MARK: The compiled bundles

  /// A module's compiled resource bundle, beside FerryUI's.
  private static func bundle(_ module: String) throws -> Bundle {
    let url = Bundle.module.bundleURL.deletingLastPathComponent()
      .appending(path: "Ferry_\(module).bundle")
    return try #require(Bundle(url: url), "no bundle for \(module)")
  }

  /// The strings of `module` in `language`, looked up the way the bundle looks up its own.
  private static func strings(_ module: String, _ language: String) throws -> Bundle {
    let path = try #require(
      try bundle(module).path(forResource: language, ofType: "lproj"),
      "\(module) has no \(language).lproj")
    return try #require(Bundle(path: path))
  }

  private static let absent = "\u{1}absent"

  /// Every string of Help, in Spanish, from the compiled FerryUI bundle.
  @Test func helpResolvesInSpanish() throws {
    let help = try #require(HelpContent.bundled)
    let spanish = try Self.strings("FerryUI", "es")
    let strings = help.categories.map(\.title) + help.topics.flatMap(\.strings)
    #expect(!strings.isEmpty)
    var untranslated: [String] = []
    for key in strings {
      let text = spanish.localizedString(forKey: key, value: Self.absent, table: nil)
      if text == Self.absent || text == key { untranslated.append(key) }
    }
    #expect(untranslated.isEmpty, "Help without Spanish: \(untranslated)")
    #expect(
      spanish.localizedString(forKey: "Troubleshooting", value: nil, table: nil)
        == "Solución de problemas")
  }

  /// The counted messages take the singular for one item in both languages.
  @Test(arguments: [
    (
      "en", "Sent %lld files to %@", "Sent 1 file to Phone", "Sent 2 files to Phone"
    ),
    (
      "es", "Sent %lld files to %@", "Se envió 1 archivo a Phone",
      "Se enviaron 2 archivos a Phone"
    ),
    (
      "en", "Couldn’t install %lld apps on %@", "Couldn’t install 1 app on Phone",
      "Couldn’t install 2 apps on Phone"
    ),
    (
      "es", "Couldn’t install %lld apps on %@", "No se pudo instalar 1 app en Phone",
      "No se pudieron instalar 2 apps en Phone"
    ),
  ])
  func countedMessagesHavePluralForms(
    language: String, key: String, one: String, two: String
  ) throws {
    let strings = try Self.strings("FerrySyncCore", language)
    let format = strings.localizedString(forKey: key, value: Self.absent, table: nil)
    #expect(String.localizedStringWithFormat(format, 1, "Phone") == one)
    #expect(String.localizedStringWithFormat(format, 2, "Phone") == two)
  }

  /// "Sent 1 of 2" is the usual partial send: the Spanish verb agrees with the first number.
  @Test func partialSendsAgreeWithTheirCount() throws {
    let strings = try Self.strings("FerrySyncCore", "es")
    let format = strings.localizedString(forKey: "Sent %lld of %lld to %@", value: nil, table: nil)
    #expect(String.localizedStringWithFormat(format, 1, 2, "Phone") == "Se envió 1 de 2 a Phone")
    #expect(String.localizedStringWithFormat(format, 2, 3, "Phone") == "Se enviaron 2 de 3 a Phone")
  }

  @Test func theAlsoNotSentLineAgreesWithItsCount() throws {
    let strings = try Self.strings("FerrySyncCore", "es")
    let format = strings.localizedString(forKey: "Also not sent: %lld.", value: nil, table: nil)
    #expect(String.localizedStringWithFormat(format, 1) == "Tampoco se envió: 1.")
    #expect(String.localizedStringWithFormat(format, 3) == "Tampoco se enviaron: 3.")
  }

  /// A capture's file name is worded in the Mac's language; its words never add a path
  /// separator, a colon or a leading dot.
  @Test func fileNamesAreTranslatedAndSafe() throws {
    // FerryUI's English is its keys.
    let spanish = try Self.strings("FerryUI", "es")
    for key in ["Screenshot %@ %@ at %@", "Screen Recording %@ %@ at %@", "Logcat %@ %@ at %@"] {
      let translated = spanish.localizedString(forKey: key, value: Self.absent, table: nil)
      #expect(translated != Self.absent, "\(key)")
      for format in [key, translated] {
        let name = String(format: format, "M", "2026-11-18", "17.09.27")
        #expect(CaptureFiles.pathSafe(name) == name, "\(name)")
      }
    }
    let screenshot = spanish.localizedString(
      forKey: "Screenshot %@ %@ at %@", value: nil, table: nil)
    #expect(
      String(format: screenshot, "M", "2026-11-18", "17.09.27")
        == "Captura de pantalla M 2026-11-18 a las 17.09.27")
  }
}
