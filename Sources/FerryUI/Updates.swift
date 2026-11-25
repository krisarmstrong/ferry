import Foundation
import Network

/// Checks for a newer Ferry. The app passes Sparkle's updater; tests pass a fake.
@MainActor
public protocol UpdateChecking: AnyObject {
  /// Shows Sparkle's window: the newer release with its notes, or that Ferry is up to date.
  func checkForUpdates()
  /// Installs the update Sparkle downloaded for the next quit, and opens Ferry again.
  func installUpdateAndRelaunch()
}

/// Where Sparkle finds releases, from the app's Info.plist. A build without a feed, or still
/// carrying the placeholder in place of the release key, has no updates.
public struct UpdateFeed: Equatable, Sendable {
  public let url: URL

  /// `nil` unless `SUFeedURL` is an HTTPS URL, or plain HTTP to this Mac (the dry run's local
  /// feed: nothing leaves the machine), and `SUPublicEDKey` is an Ed25519 public key (32 bytes,
  /// base64).
  public init?(info: [String: Any]) {
    guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
      let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false),
      scheme == "https" || (scheme == "http" && Self.isLoopback(host)),
      let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32
    else { return nil }
    self.url = url
  }

  private static func isLoopback(_ host: String) -> Bool {
    host.lowercased() == "localhost" || IPv4Address(host)?.isLoopback == true
      || IPv6Address(host)?.isLoopback == true
  }
}

extension AppModel {
  /// The menu's Check for Updates….
  public func checkForUpdates() {
    updater?.checkForUpdates()
  }

  /// The updater has downloaded an update and installs it when Ferry quits: the menu offers
  /// Update Ready — Restart Ferry.
  public func updateIsReady() {
    updateReady = true
  }

  /// Update Ready — Restart Ferry.
  public func restartToUpdate() {
    updater?.installUpdateAndRelaunch()
  }
}
