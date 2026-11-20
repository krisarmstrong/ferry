import Foundation

/// The menu's Help links: one beside a problem opens the Help topic that explains it.
extension AppModel {
  /// Asks the Help window to open the topic for the message whose catalog key is `key`. The
  /// menu then opens the window, which takes the request when it appears or, already open, at
  /// once.
  public func showHelp(forMessage key: String) {
    helpRequest = key
  }

  /// The message to open Help on, once per `showHelp(forMessage:)`.
  func takeHelpRequest() -> String? {
    defer { helpRequest = nil }
    return helpRequest
  }
}
