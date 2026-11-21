import Foundation
import Network

/// Checks for a newer Ferry. The app passes Sparkle's updater; tests pass a fake.
@MainActor
public protocol UpdateChecking: AnyObject {
  /// Shows Sparkle's window: the newer release with its notes, or that Ferry is up to date.
  func checkForUpdates()
  /// Whether a newer release is downloaded in the background and installed when Ferry quits
  /// (Sparkle's `automaticallyDownloadsUpdates`, kept in Ferry's preferences). Off, Sparkle
  /// still checks daily and asks before it downloads anything.
  var installsAutomatically: Bool { get set }
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

  /// The menu's Install Updates Automatically: on by default (Info.plist), and off when the user
  /// turned it off. Off in a build that cannot update itself, which shows no toggle.
  public var installsUpdatesAutomatically: Bool {
    _ = updateSettingChanges
    return updater?.installsAutomatically ?? false
  }

  public func setInstallsUpdatesAutomatically(_ enabled: Bool) {
    guard let updater else { return }
    updater.installsAutomatically = enabled
    updateSettingChanges += 1
  }
}
