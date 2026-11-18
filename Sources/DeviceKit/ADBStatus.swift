/// Whether adb can be used, for the menu to show.
public enum ADBStatus: Sendable, Equatable, Codable {
  case available
  /// No `adb` in any of the places Ferry looks, and no server answering.
  case notInstalled
  /// `adb` is installed but its server is not answering.
  case serverDown
}
