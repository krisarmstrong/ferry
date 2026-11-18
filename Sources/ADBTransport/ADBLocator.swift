import Foundation

/// Finds the user's installed `adb`. Ferry never bundles or downloads it: it is needed only to
/// start the server and to pair and connect, so a missing one is a state to report, not to fix.
public struct ADBLocator: Sendable {
  private let environment: [String: String]
  private let home: String
  private let isExecutable: @Sendable (String) -> Bool

  public init() {
    self.init(
      environment: ProcessInfo.processInfo.environment,
      home: NSHomeDirectory(),
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
  }

  init(
    environment: [String: String], home: String, isExecutable: @escaping @Sendable (String) -> Bool
  ) {
    self.environment = environment
    self.home = home
    self.isExecutable = isExecutable
  }

  /// The first executable `adb` among the fixed locations, in order of preference.
  public func adbURL() -> URL? {
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
