import Foundation
import Testing

@testable import PlatformTools

struct PlatformToolsFolderTests {
  private let folder = PlatformToolsFolder(home: "/Users/me")

  @Test func livesInFerrysApplicationSupportFolder() {
    #expect(folder.root.path == "/Users/me/Library/Application Support/Ferry/platform-tools")
    #expect(folder.adb(version: "37.0.3").path == "\(folder.root.path)/37.0.3/adb")
  }

  /// The pinned version first; otherwise the newest Ferry fetched before, so a Ferry update
  /// that pins a new version leaves an offline Mac its adb until the new one arrives.
  @Test(arguments: [
    (["37.0.3", "36.0.0"], "37.0.3"), (["36.0.0", "9.0.1", "36.0.10"], "36.0.10"),
    ([".staging-1", "notes", "37.0.3.partial"], nil), ([], nil),
  ])
  func choosesThePinnedVersionThenTheNewest(versions: [String], chosen: String?) {
    #expect(
      folder.installedADB(pinned: "37.0.3", in: versions, isExecutable: { _ in true })
        == chosen.map(folder.adb(version:)))
  }

  @Test func aVersionWithoutAnExecutableAdbIsSkipped() {
    let pinned = folder.adb(version: "37.0.3").path
    #expect(
      folder.installedADB(
        pinned: "37.0.3", in: ["37.0.3", "36.0.0"], isExecutable: { $0 != pinned })
        == folder.adb(version: "36.0.0"))
  }

  @Test func theFolderOnDiskIsListed() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "ferry-home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = PlatformToolsFolder(home: home.path)
    #expect(folder.installedADB(pinned: "37.0.3") == nil)
    try FileManager.default.createDirectory(
      at: folder.root.appending(path: "36.0.0"), withIntermediateDirectories: true)
    let adb = folder.adb(version: "36.0.0")
    try Data("adb".utf8).write(to: adb)
    #expect(folder.installedADB(pinned: "37.0.3") == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    #expect(folder.installedADB(pinned: "37.0.3") == adb)
  }

  @Test func theReleaseIsPinned() {
    let release = PlatformToolsRelease.pinned
    #expect(release.version == "37.0.3")
    #expect(
      release.url.absoluteString
        == "https://dl.google.com/android/repository/platform-tools_r37.0.3-darwin.zip")
    #expect(release.size == 16_597_626)
    #expect(release.sha256 == "df21339b9371fef9b19264404338dc686f59a88a1dce634b963da344909001d6")
    #expect(release.license.id == "https://developer.android.com/studio/terms")
    #expect(release.license.version.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
    #expect(release.license.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil)
  }
}
