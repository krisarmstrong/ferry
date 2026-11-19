import Foundation
import Testing

@testable import FerryAgentCore

private struct CatalogEntry: Decodable {}

private struct Catalog: Decodable {
  let strings: [String: CatalogEntry]
}

/// The agent's words come from its String Catalog: each key the code makes is in the catalog,
/// and the catalog's English reads as before.
struct AgentTextTests {
  @Test func everyStringHasItsCatalogEntry() throws {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/FerryAgentCore/Localizable.xcstrings")
    let keys = Set(try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).strings.keys)
    for resource in AgentText.all {
      #expect(keys.contains(resource.key), "\(resource.key)")
    }
  }

  @Test func theEnglishReadsAsWritten() {
    #expect(String(localized: AgentText.conflictMarker(attempt: 1)) == "conflict from Mac")
    #expect(String(localized: AgentText.conflictMarker(attempt: 12)) == "conflict from Mac 12")
    #expect(
      String(localized: AgentText.disconnected)
        == "Connect the device and choose Transfer files to see its files.")
  }
}
