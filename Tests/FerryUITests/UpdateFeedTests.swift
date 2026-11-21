import Foundation
import Testing

@testable import FerryUI

/// Ferry starts its updater only with a feed and a usable public key: a build still carrying the
/// placeholder key has no updates, rather than an updater that fails at every launch.
@MainActor
struct UpdateFeedTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let key = Data(repeating: 7, count: 32).base64EncodedString()
  private static let feed =
    "https://github.com/krisarmstrong/ferry/releases/latest/download/appcast.xml"

  @Test func aFeedAndAKeyMakeAnUpdateFeed() throws {
    let found = try #require(UpdateFeed(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key]))
    #expect(found.url.absoluteString == Self.feed)
  }

  @Test(arguments: [
    "FERRY_SPARKLE_PUBLIC_KEY_PLACEHOLDER", "", Data(repeating: 7, count: 31).base64EncodedString(),
    "$(FERRY_SPARKLE_PUBLIC_KEY)",
  ])
  func anUnusableKeyMeansNoUpdates(key: String) {
    #expect(UpdateFeed(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": key]) == nil)
  }

  @Test func aMissingFeedOrKeyMeansNoUpdates() {
    #expect(UpdateFeed(info: ["SUPublicEDKey": Self.key]) == nil)
    #expect(UpdateFeed(info: ["SUFeedURL": Self.feed]) == nil)
    #expect(UpdateFeed(info: ["SUFeedURL": "not a url", "SUPublicEDKey": Self.key]) == nil)
  }

  /// Only HTTPS reaches the network. Plain HTTP is allowed to this Mac alone, where
  /// scripts/update-dry-run.sh serves its test feed; the release check requires the HTTPS feed.
  @Test(arguments: [
    "http://github.com/krisarmstrong/ferry/releases/latest/download/appcast.xml",
    "http://192.168.1.10:8765/appcast.xml", "http://127.0.0.1.example.com/appcast.xml",
    "ftp://example.com/appcast.xml", "file:///tmp/appcast.xml",
  ])
  func aFeedThatIsNotHTTPSMeansNoUpdates(feed: String) {
    #expect(UpdateFeed(info: ["SUFeedURL": feed, "SUPublicEDKey": Self.key]) == nil)
  }

  @Test(arguments: [
    "http://127.0.0.1:8765/appcast.xml", "http://[::1]:8765/appcast.xml",
    "http://localhost:8765/appcast.xml",
  ])
  func aLoopbackFeedIsAllowed(feed: String) {
    #expect(UpdateFeed(info: ["SUFeedURL": feed, "SUPublicEDKey": Self.key]) != nil)
  }

  @Test func checkForUpdatesAsksTheUpdater() {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    let updater = FakeUpdater(log: log)
    model.updater = updater
    model.checkForUpdates()
    #expect(log.all == ["checkForUpdates"])
  }

  /// The settings Sparkle reads: the stable feed of the latest GitHub release, over HTTPS; a
  /// daily check; downloads in the background, installed when Ferry quits; a signed feed.
  @Test func theAppAsksSparkleForDailySilentSignedUpdates() throws {
    let data = try Data(contentsOf: Self.root.appending(path: "Apps/Ferry/Info.plist"))
    let info = try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(info["SUFeedURL"] as? String == "$(FERRY_FEED_URL)")
    #expect(info["SUPublicEDKey"] as? String == "$(FERRY_SPARKLE_PUBLIC_KEY)")
    #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
    #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
    #expect(info["SURequireSignedFeed"] as? Bool == true)
    #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    #expect(info["SUEnableSystemProfiling"] as? Bool == false)
    let project = try String(
      contentsOf: Self.root.appending(path: "project.yml"), encoding: .utf8)
    #expect(project.contains("\n    FERRY_FEED_URL: \(Self.feed)\n"))
  }

  /// Only a Release build carries the key, so a Debug build never starts Sparkle and never
  /// replaces itself with a release.
  @Test func onlyTheReleaseConfigurationHasTheKey() throws {
    let lines = try String(
      contentsOf: Self.root.appending(path: "project.yml"), encoding: .utf8
    ).split(separator: "\n", omittingEmptySubsequences: false)
    let keys = lines.indices.filter { lines[$0].contains("FERRY_SPARKLE_PUBLIC_KEY:") }
    #expect(keys.count == 1)
    let key = try #require(keys.first)
    #expect(lines[key].hasPrefix("      FERRY_SPARKLE_PUBLIC_KEY: "))
    let release = try #require(lines.firstIndex(of: "    Release:"))
    #expect(release > 0 && lines[release - 1] == "  configs:")
    #expect(release < key && lines[release..<key].allSatisfy { $0.hasPrefix("    ") })
  }

  /// Sparkle comes from SwiftPM at the commit of its 2.10.1 tag, not the tag, which could be
  /// moved: that commit's Package.swift fixes the framework's checksum. Only the app links it.
  @Test func sparkleIsPinnedByRevision() throws {
    let project = try String(
      contentsOf: Self.root.appending(path: "project.yml"), encoding: .utf8)
    #expect(
      project.contains(
        """
          Sparkle:
            url: https://github.com/sparkle-project/Sparkle
            # 2.10.1
            revision: ab7d71291238df6e0492143b120c9b696a35f603

        """))
  }
}

@MainActor
final class FakeUpdater: UpdateChecking {
  let log: CallLog
  var installsAutomatically = true
  init(log: CallLog) { self.log = log }
  func checkForUpdates() { log.record("checkForUpdates") }
}
