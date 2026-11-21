import Foundation
import Testing

/// No test may reach the user's real data: `SystemServices` deletes Ferry's folders in the real
/// home on Remove Ferry, unregisters the real agent and fetches into the real Application
/// Support, and the agent's default stores live there too. Only the app's entry points may name
/// them, and `AppModel` has no default `services`, so a test that forgets its fake does not
/// compile rather than running against the Mac it is on.
struct RealHomeGuardTests {
  private static let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// What reaches the real home or the real agent. `PlatformToolsFetcher` defaults its folder to
  /// `.standard`, so a test must always name its folder.
  static let banned = [
    "SystemServices(", "FerryDataRemoval.standard", "PlatformToolsFolder.standard",
    "defaultItemStore(", "defaultStore(", "defaultRecord(", "NSHomeDirectory(",
    "homeDirectoryForCurrentUser", ".applicationSupportDirectory",
  ]

  private static func swiftFiles(under folder: String) throws -> [(path: String, text: String)] {
    let base = root.appending(path: folder, directoryHint: .isDirectory)
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    else { return [] }
    var found: [(String, String)] = []
    for case let file as URL in walker where file.pathExtension == "swift" {
      found.append(
        (
          String(file.path.dropFirst(root.path.count + 1)),
          try String(contentsOf: file, encoding: .utf8)
        ))
    }
    return found
  }

  @Test func noTestNamesTheRealHomeOrTheRealServices() throws {
    let tests = try Self.swiftFiles(under: "Tests")
    #expect(tests.count > 100)
    for (path, text) in tests where !path.hasSuffix("RealHomeGuardTests.swift") {
      for name in Self.banned {
        #expect(!text.contains(name), "\(path) names \(name)")
      }
    }
  }

  /// Every test passes its own fake services: with a default, one that left them out would run
  /// Remove Ferry, the agent restarts and the fetch against this Mac.
  @Test func theModelHasNoDefaultServices() throws {
    let model = try String(
      contentsOf: Self.root.appending(path: "Sources/FerryUI/AppModel.swift"), encoding: .utf8)
    #expect(!model.contains("= SystemServices()"))
  }

  /// `PlatformToolsFetcher(` with no `folder:` would fetch into, and prune, the real folder.
  @Test func everyFetcherInTestsNamesItsFolder() throws {
    for (path, text) in try Self.swiftFiles(under: "Tests") {
      var rest = Substring(text)
      while let start = rest.range(of: "PlatformToolsFetcher(") {
        let call = rest[start.upperBound...].prefix(200)
        #expect(call.contains("folder:"), "\(path): a PlatformToolsFetcher without folder:")
        rest = rest[start.upperBound...]
      }
    }
  }
}
