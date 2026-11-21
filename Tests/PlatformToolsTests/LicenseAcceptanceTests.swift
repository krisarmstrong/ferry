import Foundation
import Testing

@testable import PlatformTools

struct LicenseAcceptanceTests {
  private let defaults: UserDefaults
  private static let license = PlatformToolsRelease.pinned.license

  init() throws {
    let suite = "ferry-license-\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  @Test func nothingIsAcceptedAtFirst() {
    #expect(LicenseAcceptance.recorded(in: defaults) == nil)
  }

  @Test func theVersionChecksumAndDateArePersisted() throws {
    let accepted = LicenseAcceptance(
      of: Self.license, date: Date(timeIntervalSince1970: 1_790_000_000))
    accepted.record(in: defaults)
    #expect(LicenseAcceptance.recorded(in: defaults) == accepted)
    #expect(accepted.version == Self.license.version)
    #expect(accepted.sha256 == Self.license.sha256)
  }

  /// Accepting a new text replaces the old acceptance.
  @Test func aLaterAcceptanceReplacesTheEarlier() {
    LicenseAcceptance(version: "older", sha256: "", date: .distantPast).record(in: defaults)
    let later = LicenseAcceptance(of: Self.license, date: Date(timeIntervalSince1970: 1))
    later.record(in: defaults)
    #expect(LicenseAcceptance.recorded(in: defaults) == later)
  }

  /// A record without its checksum covers nothing.
  @Test func aRecordWithoutItsChecksumIsNone() {
    defaults.set(
      ["version": Self.license.version, "date": Date.now], forKey: LicenseAcceptance.key)
    #expect(LicenseAcceptance.recorded(in: defaults) == nil)
  }

  /// The version and the text's checksum must both match: a text changed under the same date is
  /// accepted again.
  @Test func coversOnlyItsOwnText() {
    let accepted = LicenseAcceptance(of: Self.license, date: .now)
    #expect(accepted.covers(Self.license))
    #expect(
      !accepted.covers(
        AndroidSDKLicense(id: Self.license.id, version: "2030-01-01", sha256: Self.license.sha256)))
    #expect(
      !accepted.covers(
        AndroidSDKLicense(
          id: Self.license.id, version: Self.license.version,
          sha256: String(repeating: "0", count: 64))))
  }
}
