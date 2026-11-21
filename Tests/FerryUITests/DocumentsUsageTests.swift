import Foundation
import Testing

/// The first screenshot, recording or log saved to Documents makes macOS ask the user; the
/// question must say why Ferry wants the folder (audit L10).
struct DocumentsUsageTests {
  @Test func theAppSaysWhyItUsesDocuments() throws {
    let plist = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Apps/Ferry/Info.plist")
    let info =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: plist), format: nil) as? [String: Any]
    let purpose = try #require(info?["NSDocumentsFolderUsageDescription"] as? String)
    #expect(purpose.contains("Documents"))
  }
}
