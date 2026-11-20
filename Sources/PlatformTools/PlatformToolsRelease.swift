import Foundation

/// The text of Google's Android SDK License that Ferry shows before it downloads the platform
/// tools: its id in Google's SDK repository, a version Ferry gives the text (the date it bears),
/// and the SHA-256 of the copy Ferry bundles, so a changed text cannot keep its old version.
public struct AndroidSDKLicense: Sendable, Equatable {
  public let id: String
  public let version: String
  public let sha256: String

  public init(id: String, version: String, sha256: String) {
    self.id = id
    self.version = version
    self.sha256 = sha256
  }
}

/// One release of Google's Android SDK Platform-Tools for macOS, pinned by its size and SHA-256.
/// Ferry never ships Google's binaries: it downloads this archive once the user has accepted the
/// license, and takes only `adb` and its notices from it.
public struct PlatformToolsRelease: Sendable, Equatable {
  public let version: String
  public let url: URL
  public let size: Int
  public let sha256: String
  public let license: AndroidSDKLicense

  public init(version: String, url: URL, size: Int, sha256: String, license: AndroidSDKLicense) {
    self.version = version
    self.url = url
    self.size = size
    self.sha256 = sha256
    self.license = license
  }

  /// r37.0.3, as Google's SDK repository lists it in
  /// https://dl.google.com/android/repository/repository2-3.xml, under `android-sdk-license`. The
  /// license text is that manifest's `android-sdk-license` entry, dated January 16, 2019: the
  /// text Google's own SDK tools show for this archive. To move the pin, take the archive's
  /// version and size from that manifest and its SHA-256 from a downloaded copy; a changed
  /// license text gets a new version, which the user accepts again.
  public static let pinned = PlatformToolsRelease(
    version: "37.0.3",
    url: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.3-darwin.zip")!,
    size: 16_597_626,
    sha256: "df21339b9371fef9b19264404338dc686f59a88a1dce634b963da344909001d6",
    license: AndroidSDKLicense(
      id: "android-sdk-license", version: "2019-01-16",
      sha256: "1f8729233617b193fd619213792ae16a41b95d2bbbf525dfe66998252ba68b16"))
}

/// Why the platform tools could not be fetched. The menu words each one.
public enum PlatformToolsError: Error, Equatable, Sendable {
  /// The user has not accepted this release's license.
  case licenseNotAccepted
  /// The release's address is not HTTPS, or the download was redirected off it.
  case insecureAddress
  /// The Mac is offline or Google could not be reached.
  case offline
  /// Google answered, but not with the archive.
  case downloadFailed
  /// The archive is not the pinned one: its size or checksum differs.
  case mismatch
  /// The archive cannot be read, holds an unsafe entry, or has no `adb`.
  case badArchive
  /// The extracted `adb` is not signed by Google.
  case notSigned
  /// Ferry could not write to its folder.
  case storage
  case cancelled
}
