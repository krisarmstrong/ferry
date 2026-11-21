import Foundation
import PlatformTools

/// Finds the `adb` that starts the server and pairs and connects. A server already answering is
/// used as it is, whichever adb started it, and never needs one; Ferry stops only a server its
/// own agent started (see `ADBServerKeeper`).
///
/// In order: the `adb` Ferry fetched from Google (see `PlatformToolsFetcher`), checked against
/// Google's signature again whenever the file changed since it last passed, then one already on
/// this Mac, in the places Homebrew, Android Studio and `ANDROID_HOME` put it. The agent runs
/// without the user's shell, so there is no `PATH` to search.
public struct ADBLocator: Sendable {
  private let environment: [String: String]
  private let home: String
  private let isExecutable: @Sendable (String) -> Bool
  private let fetched: @Sendable () -> URL?
  private let isGoogleSigned: @Sendable (URL) -> Bool

  public init() {
    self.init(
      environment: ProcessInfo.processInfo.environment,
      home: NSHomeDirectory(),
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
      isGoogleSigned: CodeSignature.isGoogleSigned)
  }

  /// `fetched` defaults to the newest usable version in Ferry's folder under `home`.
  init(
    environment: [String: String], home: String,
    isExecutable: @escaping @Sendable (String) -> Bool,
    fetched: (@Sendable () -> URL?)? = nil,
    isGoogleSigned: @escaping @Sendable (URL) -> Bool = { _ in false }
  ) {
    self.environment = environment
    self.home = home
    self.isExecutable = isExecutable
    self.fetched =
      fetched ?? {
        PlatformToolsFolder(home: home).installedADB(pinned: PlatformToolsRelease.pinned.version)
      }
    self.isGoogleSigned = isGoogleSigned
  }

  /// Ferry's fetched `adb`, if Google's signature holds on it.
  public func fetchedADB() -> URL? {
    fetched().flatMap { isGoogleSigned($0) ? $0 : nil }
  }

  /// Ferry's fetched `adb` if Google's signature holds on it, else the first executable `adb`
  /// among the fixed locations, in order of preference.
  public func adbURL() -> URL? {
    if let fetched = fetchedADB() { return fetched }
    var candidates = [
      "/opt/homebrew/bin/adb",
      "/usr/local/bin/adb",
      "\(home)/Library/Android/sdk/platform-tools/adb",
    ]
    if let sdk = environment["ANDROID_HOME"], !sdk.isEmpty {
      candidates.append("\(sdk)/platform-tools/adb")
    }
    return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
  }
}
