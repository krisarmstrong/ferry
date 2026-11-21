import Foundation
import Testing

@testable import ADBTransport

struct ADBLocatorTests {
  func locator(
    existing: Set<String>, androidHome: String? = nil
  ) -> ADBLocator {
    ADBLocator(
      environment: androidHome.map { ["ANDROID_HOME": $0] } ?? [:], home: "/Users/me",
      isExecutable: { existing.contains($0) })
  }

  @Test func nothingInstalled() {
    #expect(locator(existing: []).adbURL() == nil)
  }

  @Test func homebrewWinsOverEverything() {
    let all: Set = [
      "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
      "/Users/me/Library/Android/sdk/platform-tools/adb", "/sdk/platform-tools/adb",
    ]
    #expect(locator(existing: all, androidHome: "/sdk").adbURL()?.path == "/opt/homebrew/bin/adb")
  }

  @Test func searchOrder() {
    #expect(
      locator(existing: ["/usr/local/bin/adb", "/Users/me/Library/Android/sdk/platform-tools/adb"])
        .adbURL()?.path == "/usr/local/bin/adb")
    #expect(
      locator(
        existing: ["/Users/me/Library/Android/sdk/platform-tools/adb", "/sdk/platform-tools/adb"],
        androidHome: "/sdk"
      )
      .adbURL()?.path == "/Users/me/Library/Android/sdk/platform-tools/adb")
  }

  @Test func androidHomeIsLast() {
    #expect(
      locator(existing: ["/sdk/platform-tools/adb"], androidHome: "/sdk").adbURL()?.path
        == "/sdk/platform-tools/adb")
  }

  @Test func androidHomeIgnoredWhenUnset() {
    #expect(locator(existing: ["/platform-tools/adb"]).adbURL() == nil)
  }

  private static let fetched = URL(
    filePath: "/Users/me/Library/Application Support/Ferry/platform-tools/37.0.3/adb")

  /// The adb Ferry fetched comes before any other; a running server, whichever adb started it,
  /// is used as it is and never needs the locator.
  @Test func ferrysFetchedAdbWinsOverEverything() {
    let locator = ADBLocator(
      environment: [:], home: "/Users/me", isExecutable: { $0 == "/opt/homebrew/bin/adb" },
      fetched: { Self.fetched }, isGoogleSigned: { $0 == Self.fetched })
    #expect(locator.adbURL() == Self.fetched)
  }

  /// A fetched adb whose signature no longer holds is never run: the Mac's own adb is used.
  @Test func aFetchedAdbNotSignedByGoogleIsSkipped() {
    let locator = ADBLocator(
      environment: [:], home: "/Users/me", isExecutable: { $0 == "/opt/homebrew/bin/adb" },
      fetched: { Self.fetched }, isGoogleSigned: { _ in false })
    #expect(locator.adbURL()?.path == "/opt/homebrew/bin/adb")
  }

  @Test func withoutAFetchedAdbTheMacsOwnIsUsed() {
    let locator = ADBLocator(
      environment: [:], home: "/Users/me", isExecutable: { $0 == "/usr/local/bin/adb" },
      fetched: { nil }, isGoogleSigned: { _ in true })
    #expect(locator.adbURL()?.path == "/usr/local/bin/adb")
  }

  /// The real locator looks in Ferry's folder in the home it is given.
  @Test func theDefaultLookupReadsFerrysFolder() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "ferry-home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = home.appending(path: "Library/Application Support/Ferry/platform-tools/37.0.3")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let adb = folder.appending(path: "adb")
    try Data("#!/bin/sh\n".utf8).write(to: adb)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    let signed = ADBLocator(
      environment: [:], home: home.path, isExecutable: { _ in false },
      isGoogleSigned: { _ in true })
    #expect(signed.adbURL()?.path == adb.path)
    let unsigned = ADBLocator(
      environment: [:], home: home.path, isExecutable: { _ in false },
      isGoogleSigned: { _ in false })
    #expect(unsigned.adbURL() == nil)
  }
}
