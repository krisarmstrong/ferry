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
    #expect(
      String(localized: ProviderText.sizeMismatch(expected: 2, actual: 1))
        == "The device stored 1 bytes where 2 were sent.")
    #expect(
      String(localized: ProviderText.folderTooDeep("Deep"))
        == "“Deep” holds folders nested more than 64 deep, which Ferry does not delete.")
    #expect(
      String(localized: ProviderText.link)
        == "Symbolic links and aliases can’t be copied to the device.")
  }
}
