import DeviceKit
import Foundation
import Testing

@testable import FerryUI

private struct CatalogEntry: Decodable {}

private struct Catalog: Decodable {
  let strings: [String: CatalogEntry]
}

/// A string the code builds with values must have the key its interpolation makes, or the
/// catalog's entry is never found: a `UInt16` makes `%u`, not the `%lld` an `Int` makes. Ports
/// are text, so they are not grouped (`8,080`).
struct CatalogKeysTests {
  private func catalogKeys() throws -> Set<String> {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/FerryUI/Localizable.xcstrings")
    return Set(try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).strings.keys)
  }

  @Test func theForwardStringsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    let forward = PortForward(local: 8080, remote: 80)
    #expect(keys.contains(DevicePresentation.forwardLineResource(forward).key))
    #expect(keys.contains(DevicePresentation.removeForwardResource(forward).key))
  }

  @Test func theForwardStringsReadInPlainWords() {
    let forward = PortForward(local: 8080, remote: 80)
    #expect(DevicePresentation.forwardLine(forward) == "This Mac port 8080 → device port 80")
    #expect(
      DevicePresentation.removeForwardLabel(forward) == "Remove the forward from port 8080")
  }

  /// Every row the menu lists, and the summary of a remembered device, has its catalog entry.
  @Test func theMenuRowsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    for action in DevicePresentation.MenuAction.allCases {
      #expect(keys.contains(action.title.key), "\(action)")
    }
    #expect(keys.contains("Remembered · not nearby"))
  }
}
