import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryProviderCore

private struct CatalogEntry: Decodable {}

private struct Catalog: Decodable {
  let strings: [String: CatalogEntry]
}

/// The errors the extension builds come from its String Catalog: each key the code makes is in
/// the catalog, and the catalog's English reads as before.
struct ProviderTextTests {
  @Test func everyStringHasItsCatalogEntry() throws {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/FerryProviderCore/Localizable.xcstrings")
    let keys = Set(try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).strings.keys)
    for resource in ProviderText.all {
      #expect(keys.contains(resource.key), "\(resource.key)")
    }
  }

  @Test func theEnglishReadsAsWritten() {
    #expect(
      String(localized: ProviderText.nameChanged(requested: "Résumé.txt", actual: "RESUME.TXT"))
        == "The device saved “Résumé.txt” as “RESUME.TXT”.")
    // Its plural forms are checked compiled, below: an uncompiled catalog reads as its key.
    #expect(
      ProviderText.sizeMismatch(expected: 2, actual: 1).key
        == "The device stored %llu bytes where %llu were sent.")
    #expect(
      String(localized: ProviderText.folderTooDeep("Deep"))
        == "“Deep” holds folders nested more than 64 deep, which Ferry does not delete.")
    #expect(
      String(localized: ProviderText.link)
        == "Symbolic links and aliases can’t be copied to the device.")
  }

  /// A byte count agrees with its number, in English and in Spanish, once compiled.
  @Test func byteCountsAgreeWithTheirNumber() throws {
    let key = "The device stored %llu bytes where %llu were sent."
    let catalog = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/FerryProviderCore/Localizable.xcstrings")
    func format(_ language: String) throws -> String {
      try CompiledCatalog.strings(catalog, language: language)
        .localizedString(forKey: key, value: nil, table: nil)
    }
    #expect(
      String.localizedStringWithFormat(try format("en"), UInt64(0), UInt64(1))
        == "The device stored 0 bytes where 1 was sent.")
    #expect(
      String.localizedStringWithFormat(try format("es"), UInt64(1), UInt64(2))
        == "El dispositivo guardó 1 byte, pero se enviaron 2.")
  }
}
