import AppKit
import FerryUI
import Sparkle

/// Sparkle's updater: a check each day, the download in the background and the install when
/// Ferry quits, always (owner, 2026-11-21), and only an update signed with Ferry's key from a
/// signed feed.
@MainActor
final class SparkleUpdates: UpdateChecking {
  private let controller: SPUStandardUpdaterController

  /// `nil`, and Sparkle never starts, when the build has no feed or no release key (see
  /// `UpdateFeed`).
  init?(bundle: Bundle = .main) {
    guard UpdateFeed(info: bundle.infoDictionary ?? [:]) != nil else { return nil }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    // Ferry has no switch for this: a choice an earlier version saved does not turn it off.
    controller.updater.automaticallyChecksForUpdates = true
    controller.updater.automaticallyDownloadsUpdates = true
  }

  func checkForUpdates() {
    NSApp.activate()
    controller.checkForUpdates(nil)
  }
}
