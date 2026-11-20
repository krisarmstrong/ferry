import Foundation
import Testing

@testable import PlatformTools

struct LicenseAcceptanceTests {
  private let defaults: UserDefaults

  init() throws {
    let suite = "ferry-license-\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  @Test func nothingIsAcceptedAtFirst() {
    #expect(LicenseAcceptance.recorded(in: defaults) == nil)
  }

  @Test func theVersionAndDateArePersisted() throws {
    let accepted = LicenseAcceptance(
      version: "2019-01-16", date: Date(timeIntervalSince1970: 1_790_000_000))
    accepted.record(in: defaults)
    #expect(LicenseAcceptance.recorded(in: defaults) == accepted)
  }

  /// Accepting a new text replaces the old acceptance.
  @Test func aLaterAcceptanceReplacesTheEarlier() {
    LicenseAcceptance(version: "2012-11-13", date: .distantPast).record(in: defaults)
    let later = LicenseAcceptance(version: "2019-01-16", date: Date(timeIntervalSince1970: 1))
    later.record(in: defaults)
    #expect(LicenseAcceptance.recorded(in: defaults) == later)
  }

  @Test func coversOnlyItsOwnVersion() {
    let accepted = LicenseAcceptance(version: "2019-01-16", date: .now)
    #expect(accepted.covers(PlatformToolsRelease.pinned.license))
    #expect(
      !accepted.covers(
        AndroidSDKLicense(id: "android-sdk-license", version: "2030-01-01", sha256: "")))
  }
}
