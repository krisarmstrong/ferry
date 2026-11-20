import CryptoKit
import DeviceKit
import FerryIPC
import Foundation
import PlatformTools
import Testing

@testable import FerryUI

/// Get Android Platform Tools…: the license, the download, and what the menu says about them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelPlatformToolsTests {
  let log = CallLog()
  private static let pinnedLicense = PlatformToolsRelease.pinned.license.version

  private func model(_ client: FakeClient, _ services: FakeServices) -> AppModel {
    AppModel(client: client, services: services)
  }

  private func missingAdb() -> (FakeClient, FakeServices) {
    let client = FakeClient(log: log)
    client.setStatus([device("A1", model: "Pixel 8", .ready([]))], adb: .notInstalled)
    return (client, FakeServices(log: log))
  }

  /// A Mac with no Android device has no use for adb, so the menu does not offer it.
  @Test(arguments: [
    (ADBStatus?.some(.notInstalled), true, true), (.some(.notInstalled), false, false),
    (.some(.available), true, false), (.some(.serverDown), true, false), (nil, true, false),
  ])
  func theOfferShowsOnlyWithADeviceAndNoAdb(
    status: ADBStatus?, withDevice: Bool, shows: Bool
  ) async {
    let client = FakeClient(log: log)
    client.setStatus(withDevice ? [device("A1", model: "Pixel 8", .ready([]))] : [], adb: status)
    let model = model(client, FakeServices(log: log))
    await model.refresh()
    #expect(model.platformToolsRow == (shows ? .offer : nil))
  }

  @Test func acceptingRecordsTheLicenseThenFetchesThenAsksTheAgentToLookAgain() async {
    let (client, services) = missingAdb()
    let model = model(client, services)
    await model.refresh()
    client.setStatus([device("A1", model: "Pixel 8", .ready([]))], adb: .available)
    model.acceptLicense()
    #expect(model.platformToolsRow == .fetching)
    await model.platformToolsSettled()
    #expect(
      log.all.suffix(4) == [
        "acceptLicense \(Self.pinnedLicense)", "fetchPlatformTools \(Self.pinnedLicense)",
        "recheckADB", "status",
      ])
    #expect(services.acceptance?.version == Self.pinnedLicense)
    #expect(model.platformToolsRow == nil)
  }

  @Test func anOfflineMacIsToldItNeedsTheInternetOnce() async {
    let (client, services) = missingAdb()
    services.fetchOutcomes = [.offline]
    let model = model(client, services)
    await model.refresh()
    model.acceptLicense()
    await model.platformToolsSettled()
    #expect(model.platformToolsRow == .failed(.offline))
    #expect(!log.all.contains("recheckADB"))
  }

  /// Try Again uses the acceptance already recorded: the license is not shown again.
  @Test func tryAgainFetchesAgain() async {
    let (client, services) = missingAdb()
    services.fetchOutcomes = [.mismatch]
    let model = model(client, services)
    await model.refresh()
    model.acceptLicense()
    await model.platformToolsSettled()
    #expect(model.platformToolsRow == .failed(.mismatch))
    client.setStatus([device("A1", model: "Pixel 8", .ready([]))], adb: .available)
    model.retryPlatformTools()
    await model.platformToolsSettled()
    #expect(log.all.filter { $0.hasPrefix("acceptLicense") }.count == 1)
    #expect(log.all.filter { $0.hasPrefix("fetchPlatformTools") }.count == 2)
    #expect(model.platformToolsRow == nil)
  }

  /// Use adb Already on This Mac is the agent looking again, and puts the offer back.
  @Test func usingTheMacsAdbClearsTheFailureAndAsksTheAgent() async {
    let (client, services) = missingAdb()
    services.fetchOutcomes = [.offline]
    let model = model(client, services)
    await model.refresh()
    model.acceptLicense()
    await model.platformToolsSettled()
    await model.useExistingADB()
    #expect(log.all.suffix(2) == ["recheckADB", "status"])
    #expect(model.platformToolsRow == .offer)
  }

  /// adb that turns up another way (the user installed it) ends a failed download's line.
  @Test func aFailureEndsWhenAdbTurnsUp() async {
    let (client, services) = missingAdb()
    services.fetchOutcomes = [.offline]
    let model = model(client, services)
    await model.refresh()
    model.acceptLicense()
    await model.platformToolsSettled()
    await model.refresh()
    #expect(model.platformToolsRow == .failed(.offline))
    client.setStatus([device("A1", model: "Pixel 8", .ready([]))], adb: .available)
    await model.refresh()
    #expect(model.platformToolsRow == nil)
  }

  /// A failed update under a changed license stays shown: adb was there all along.
  @Test func aFailedUpdateStaysWhileTheOldAdbServes() async {
    let client = FakeClient(log: log)
    client.setStatus([], adb: .available)
    let services = FakeServices(log: log)
    services.fetchedVersion = "36.0.0"
    services.acceptance = LicenseAcceptance(version: "2012-11-13", date: .distantPast)
    services.fetchOutcomes = [.offline]
    let model = model(client, services)
    await model.launch()
    model.acceptLicense()
    await model.platformToolsSettled()
    await model.refresh()
    #expect(model.platformToolsRow == .failed(.offline))
  }

  @Test func cancelStopsTheDownload() async {
    let (client, services) = missingAdb()
    services.holdsFetch = true
    let model = model(client, services)
    await model.refresh()
    model.acceptLicense()
    var held = services.fetchesHeld.makeAsyncIterator()
    await held.next()
    model.cancelPlatformTools()
    await model.platformToolsSettled()
    #expect(model.platformToolsRow == .offer)
    #expect(!log.all.contains("recheckADB"))
  }

  /// A Ferry release that pins a new version fetches it quietly when the license is the one
  /// the user accepted.
  @Test func launchFetchesANewVersionQuietlyUnderTheSameLicense() async {
    let client = FakeClient(log: log)
    client.setStatus([], adb: .available)
    let services = FakeServices(log: log)
    services.fetchedVersion = "36.0.0"
    services.acceptance = LicenseAcceptance(version: Self.pinnedLicense, date: .distantPast)
    let model = model(client, services)
    await model.launch()
    #expect(model.platformToolsRow == nil)
    await model.platformToolsSettled()
    #expect(log.all.contains("fetchPlatformTools \(Self.pinnedLicense)"))
    #expect(model.platformToolsRow == nil)
  }

  /// A changed license is accepted again first; meanwhile the adb Ferry has stays in use.
  @Test func launchAsksAgainWhenTheLicenseChanged() async {
    let client = FakeClient(log: log)
    client.setStatus([], adb: .available)
    let services = FakeServices(log: log)
    services.fetchedVersion = "36.0.0"
    services.acceptance = LicenseAcceptance(version: "2012-11-13", date: .distantPast)
    let model = model(client, services)
    await model.launch()
    await model.platformToolsSettled()
    #expect(model.platformToolsRow == .licenseChanged)
    #expect(!log.all.contains { $0.hasPrefix("fetchPlatformTools") })
    model.acceptLicense()
    await model.platformToolsSettled()
    #expect(model.platformToolsRow == nil)
  }

  @Test(arguments: ["37.0.3", nil])
  func launchLeavesACurrentOrAbsentCopyAlone(version: String?) async {
    let client = FakeClient(log: log)
    client.setStatus([], adb: .available)
    let services = FakeServices(log: log)
    services.fetchedVersion = version
    services.acceptance = LicenseAcceptance(version: "2012-11-13", date: .distantPast)
    let model = model(client, services)
    await model.launch()
    await model.platformToolsSettled()
    #expect(model.platformToolsRow == nil)
    #expect(!log.all.contains { $0.hasPrefix("fetchPlatformTools") })
  }

  /// Each failure is one of the messages Help explains.
  @Test(arguments: [
    (PlatformToolsError.offline, "Couldn't download adb. Ferry needs an internet connection once."),
    (.downloadFailed, "Couldn't download adb. Ferry needs an internet connection once."),
    (.mismatch, "The download didn't pass Ferry's checks, so Ferry deleted it."),
    (.badArchive, "The download didn't pass Ferry's checks, so Ferry deleted it."),
    (.notSigned, "The download didn't pass Ferry's checks, so Ferry deleted it."),
    (.insecureAddress, "The download didn't pass Ferry's checks, so Ferry deleted it."),
    (.storage, "Ferry couldn't save adb in its folder."),
    (.licenseNotAccepted, "adb isn't on this Mac"), (.cancelled, "adb isn't on this Mac"),
  ])
  func eachFailureHasItsMessage(error: PlatformToolsError, message: String) {
    #expect(MenuStatusText.platformTools(.failed(error)).key == message)
  }

  /// The license Ferry shows is the text whose version the user accepts.
  @Test func theBundledLicenseIsThePinnedText() throws {
    let text = try #require(PlatformToolsLicenseView.licenseText)
    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == PlatformToolsRelease.pinned.license.sha256)
    #expect(text.hasPrefix("Terms and Conditions\n\nThis is the Android Software Development Kit"))
  }
}
