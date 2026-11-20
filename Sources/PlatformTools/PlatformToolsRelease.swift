import Foundation

/// The text of Google's Android SDK License that Ferry shows before it downloads the platform
/// tools: where Google publishes it, its version (the date it bears), and the SHA-256 of the copy
/// Ferry bundles. An acceptance covers one version and checksum, so a changed text is accepted
/// again.
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
  /// https://dl.google.com/android/repository/repository2-3.xml. To move the pin, take the
  /// archive's version and size from that manifest and its SHA-256 from a downloaded copy.
  ///
  /// The license is Google's current Android SDK License Agreement, from
  /// https://developer.android.com/studio/terms, dated April 28, 2026: the text of the page's
  /// `sdk-terms` block, its headings and date as plain lines, HTML entities decoded, nothing else
  /// changed (`Sources/FerryUI/android-sdk-license.txt`). The manifest's own
  /// `android-sdk-license` entry is an older text (January 16, 2019). To move it, transcribe the
  /// page the same way and set its date and checksum here.
  public static let pinned = PlatformToolsRelease(
    version: "37.0.3",
    url: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.3-darwin.zip")!,
    size: 16_597_626,
    sha256: "df21339b9371fef9b19264404338dc686f59a88a1dce634b963da344909001d6",
    license: AndroidSDKLicense(
      id: "https://developer.android.com/studio/terms", version: "2026-04-28",
      sha256: "a28708e39abd4bb67c9652344b64b5534bb65df868c062abca9a23c24d37b125"))
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
