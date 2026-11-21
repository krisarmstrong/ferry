import Foundation

/// That the user accepted a text of the Android SDK License, by its version and checksum, and
/// when. Kept in the app's defaults; another text, even under the same version, needs a new
/// acceptance.
public struct LicenseAcceptance: Sendable, Equatable {
  public let version: String
  public let sha256: String
  public let date: Date

  public init(version: String, sha256: String, date: Date) {
    self.version = version
    self.sha256 = sha256
    self.date = date
  }

  public init(of license: AndroidSDKLicense, date: Date) {
    self.init(version: license.version, sha256: license.sha256, date: date)
  }

  static let key = "AndroidSDKLicenseAcceptance"

  public static func recorded(in defaults: UserDefaults) -> LicenseAcceptance? {
    guard let record = defaults.dictionary(forKey: key),
      let version = record["version"] as? String, let sha256 = record["sha256"] as? String,
      let date = record["date"] as? Date
    else { return nil }
    return LicenseAcceptance(version: version, sha256: sha256, date: date)
  }

  public func record(in defaults: UserDefaults) {
    defaults.set(["version": version, "sha256": sha256, "date": date], forKey: Self.key)
  }

  public func covers(_ license: AndroidSDKLicense) -> Bool {
    version == license.version && sha256 == license.sha256
  }
}
