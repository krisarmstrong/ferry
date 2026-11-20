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
  private static let catalogURL = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/FerryUI/Localizable.xcstrings")

  private func catalogKeys() throws -> Set<String> {
    Set(
      try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Self.catalogURL)).strings.keys)
  }

  /// A key written twice decodes as one, so the duplicate goes unseen until Xcode or an export
  /// trips on it. Xcode writes each key of `strings` on its own line, indented four spaces: the
  /// raw text must have as many of those as the decoded catalog has keys.
  @Test func noKeyIsWrittenTwice() throws {
    let text = try String(contentsOf: Self.catalogURL, encoding: .utf8)
    let written = text.split(separator: "\n").filter {
      $0.hasPrefix("    \"") && !$0.hasPrefix("     ") && $0.hasSuffix(" : {")
    }
    var seen = Set<Substring>()
    let repeated = written.filter { !seen.insert($0).inserted }
    #expect(repeated.isEmpty, "written twice: \(repeated)")
    #expect(written.count == (try catalogKeys()).count)
  }

  @Test func theForwardStringsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    let forward = PortForward(local: 8080, remote: 80)
    #expect(keys.contains(DevicePresentation.forwardLineResource(forward).key))
    #expect(keys.contains(DevicePresentation.removeForwardResource(forward).key))
  }

  @Test func theForwardStringsReadInPlainWords() {
    let forward = PortForward(local: 8080, remote: 80)
    #expect(DevicePresentation.forwardLine(forward) == "Mac 8080 → Device 80")
    #expect(DevicePresentation.removeForwardLabel(forward) == "Remove forward 8080")
  }

  /// Every row the menu lists, and the summary of a remembered device, has its catalog entry.
  @Test func theMenuRowsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    for action in DevicePresentation.MenuAction.allCases {
      #expect(keys.contains(action.title.key), "\(action)")
    }
    #expect(keys.contains("Remembered · not nearby"))
    // The rows' old names are gone with them.
    #expect(!keys.contains("Open Shell"))
    #expect(!keys.contains("Forget"))
  }

  /// The menu's footer after Settings went: Open at Login, in title case, and its failure.
  @Test func theFooterStringsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    #expect(keys.contains(MenuFooter.openAtLoginResource.key))
    #expect(String(localized: MenuFooter.openAtLoginResource) == "Open at Login")
    #expect(!keys.contains("Open at login"))
    #expect(!keys.contains("Settings…"))
  }

  /// The setup guide's topics, which its picker shows.
  @Test func theGuideTopicsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    for topic in GuideTopic.allCases {
      #expect(keys.contains(topic.title.key), "\(topic)")
    }
  }

  /// The names of a known model's ports, and the word for one with no address.
  @Test func theKnownPortsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    for name in [
      "Wi-Fi Management", "Wired Management", "Wired Test", "Wi-Fi Test", "Not connected",
    ] {
      #expect(keys.contains(name), "\(name)")
    }
  }

  /// The inline details: the system line in each of its forms, the copy actions and the words
  /// shown while loading and once copied.
  @Test func theDetailStringsHaveCatalogKeys() throws {
    let keys = try catalogKeys()
    for (version, battery) in [
      ("8.1.0", AndroidDeviceInfo.Battery(level: 87, state: .full)), ("8.1.0", nil),
      ("", AndroidDeviceInfo.Battery(level: 87, state: .full)),
    ] {
      let info = AndroidDeviceInfo(
        model: "M", androidVersion: version, build: "", serial: "S", battery: battery,
        addresses: [], storage: nil)
      let resource = try #require(DevicePresentation.systemLineResource(info))
      #expect(keys.contains(resource.key), "\(resource.key)")
    }
    let line = DevicePresentation.DetailLine(id: "wlan0", label: "Wi-Fi", address: "192.0.2.1")
    #expect(keys.contains(DevicePresentation.copyAddressResource(line).key))
    #expect(keys.contains(DevicePresentation.loadingDetailsResource.key))
    #expect(keys.contains(DevicePresentation.copiedResource.key))
    #expect(keys.contains(DevicePresentation.copiedAllResource.key))
    #expect(keys.contains(DevicePresentation.copyAllDetailsResource.key))
    #expect(!keys.contains("Copy Device Details"))
    // A label that names its interface, "Wi-Fi (wlan1)".
    #expect(keys.contains("%@ (%@)"))
  }
}
