import Foundation

/// What a Help link asks the Help window to open.
enum HelpRequest: Equatable {
  /// The topic that explains the message with this catalog key, marked.
  case message(String)
  /// The topic with this id.
  case topic(String)
}

/// The menu's Help links: one beside a problem opens the Help topic that explains it.
extension AppModel {
  /// Asks the Help window to open the topic for the message whose catalog key is `key`. The
  /// menu then opens the window, which takes the request when it appears or, already open, at
  /// once.
  public func showHelp(forMessage key: String) {
    helpRequest = .message(key)
  }

  /// Asks the Help window to open the topic with this id: a welcome step's link.
  public func showHelp(topic id: String) {
    helpRequest = .topic(id)
  }

  /// What to open Help on, once per `showHelp`.
  func takeHelpRequest() -> HelpRequest? {
    defer { helpRequest = nil }
    return helpRequest
  }
}
