import AppKit
import FerryUI
import Sparkle

/// Sparkle's updater. Info.plist sets the rest: a check each day, the download in the
/// background, the install when Ferry quits, and only an update signed with Ferry's key from a
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
  }

  func checkForUpdates() {
    NSApp.activate()
    controller.checkForUpdates(nil)
  }
}
