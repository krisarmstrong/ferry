import Foundation

/// Checks for a newer Ferry. The app passes Sparkle's updater; tests pass a fake.
@MainActor
public protocol UpdateChecking: AnyObject {
  /// Shows Sparkle's window: the newer release with its notes, or that Ferry is up to date.
  func checkForUpdates()
}

/// Where Sparkle finds releases, from the app's Info.plist. A build without a feed, or still
/// carrying the placeholder in place of the release key, has no updates.
public struct UpdateFeed: Equatable, Sendable {
  public let url: URL

  /// `nil` unless `SUFeedURL` is an absolute URL and `SUPublicEDKey` is an Ed25519 public key
  /// (32 bytes, base64).
  public init?(info: [String: Any]) {
    guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme != nil,
      let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32
    else { return nil }
    self.url = url
  }
}

extension AppModel {
  /// The menu's Check for Updates….
  public func checkForUpdates() {
    updater?.checkForUpdates()
  }
}
