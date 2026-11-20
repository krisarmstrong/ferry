import Foundation
import Testing

/// An address the UI shows as an example, such as a field's prompt, is from a documentation
/// range (RFC 5737): it can never be someone's real device.
struct DocumentationAddressTests {
  @Test func theUIShowsOnlyDocumentationAddresses() throws {
    let folder = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/FerryUI")
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    var found: [String] = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for match in source.matches(of: /"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/) {
        let address = String(match.output.1)
        let documentation = ["192.0.2.", "198.51.100.", "203.0.113."].contains {
          address.hasPrefix($0)
        }
        if !documentation { found.append("\(file.lastPathComponent): \(address)") }
      }
    }
    #expect(found.isEmpty, "\(found)")
  }
}
