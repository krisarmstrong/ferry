import Foundation

/// That the user accepted a version of the Android SDK License, and when. Kept in the app's
/// defaults; a release whose license has another version needs a new acceptance.
public struct LicenseAcceptance: Sendable, Equatable {
  public let version: String
  public let date: Date

  public init(version: String, date: Date) {
    self.version = version
    self.date = date
  }

  static let key = "AndroidSDKLicenseAcceptance"

  public static func recorded(in defaults: UserDefaults) -> LicenseAcceptance? {
    guard let record = defaults.dictionary(forKey: key),
      let version = record["version"] as? String, let date = record["date"] as? Date
    else { return nil }
    return LicenseAcceptance(version: version, date: date)
  }

  public func record(in defaults: UserDefaults) {
    defaults.set(["version": version, "date": date], forKey: Self.key)
  }

  public func covers(_ license: AndroidSDKLicense) -> Bool {
    version == license.version
  }
}
