import Foundation

/// The `adb` a shell in Terminal runs (see `ADBDeviceTools.shellADB()`).
public struct ShellADB: Sendable, Equatable {
  public let url: URL
  /// Whether it is the program serving the adb server's port. False when Ferry could not tell
  /// which program that is and fell back to the adb the locator finds: an adb client of another
  /// version than the server may restart it.
  public let runsServer: Bool

  public init(url: URL, runsServer: Bool) {
    self.url = url
    self.runsServer = runsServer
  }
}
