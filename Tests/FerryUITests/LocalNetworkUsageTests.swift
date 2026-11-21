import Foundation
import Testing

/// macOS asks before a program reaches the local network (TN3179), and holds the adb server the
/// agent starts to the agent's answer. The agent's embedded plist and the app's both say why
/// Ferry needs it, and name the mDNS services adb browses for wireless debugging. English only:
/// a bundle-less tool cannot localise its embedded plist. `make check-app` checks the built app.
struct LocalNetworkUsageTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static func plist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appending(path: path))
    return try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }

  @Test(arguments: ["Apps/FerryAgent/Info.plist", "Apps/Ferry/Info.plist"])
  func declaresLocalNetworkUse(_ path: String) throws {
    let plist = try Self.plist(path)
    #expect(
      plist["NSLocalNetworkUsageDescription"] as? String
        == "Ferry connects to Android devices on your network over Wi-Fi.")
    #expect(
      plist["NSBonjourServices"] as? [String] == ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"])
  }
}
