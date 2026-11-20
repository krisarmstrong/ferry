import Foundation
import Testing

@testable import FerryUI

private struct CatalogUsageEntry: Decodable {}

/// Every key in the catalog is still shown somewhere: a key no code and no help uses is a
/// leftover that translators would work on for nothing.
struct CatalogUsageTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private struct Catalog: Decodable {
    let strings: [String: CatalogUsageEntry]
  }

  /// The FerryUI sources: each one-line literal as written, and each multi-line literal with its
  /// indentation and line continuations removed, as Swift reads it.
  private static func literals() throws -> (text: String, multiLine: Set<String>) {
    let folder = root.appending(path: "Sources/FerryUI")
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    var text = ""
    var multiLine = Set<String>()
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      text += source
      let blocks = source.split(separator: "\"\"\"", omittingEmptySubsequences: false)
      // Every other piece lies between a pair of triple quotes.
      for index in blocks.indices where index % 2 == 1 {
        let block = blocks[index]
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
          .dropFirst().dropLast()
          .map { $0.drop { $0 == " " } }
        multiLine.insert(lines.joined(separator: "\n").replacingOccurrences(of: "\\\n", with: ""))
      }
    }
    return (text, multiLine)
  }

  @Test func everyKeyIsUsed() throws {
    let catalog = try JSONDecoder().decode(
      Catalog.self,
      from: Data(contentsOf: Self.root.appending(path: "Sources/FerryUI/Localizable.xcstrings")))
    let content = HelpContent.bundled
    let help = Set(
      (content?.categories.map(\.title) ?? []) + (content?.topics ?? []).flatMap(\.strings))
    #expect(!help.isEmpty)
    let (text, multiLine) = try Self.literals()
    // A key with a format specifier is made by an interpolation, which no literal spells out.
    let unused = catalog.strings.keys.filter { key in
      guard !key.contains("%") else { return false }
      let literal = "\"" + key.replacingOccurrences(of: "\"", with: "\\\"") + "\""
      return !help.contains(key) && !text.contains(literal) && !multiLine.contains(key)
    }
    #expect(unused.isEmpty, "not used: \(unused.sorted())")
  }
}
