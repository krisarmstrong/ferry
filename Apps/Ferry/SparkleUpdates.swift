import AppKit
import FerryUI
import Sparkle

/// Sparkle's updater: a check each day, the download in the background and the install when
/// Ferry quits, always (owner, 2026-11-21), and only an update signed with Ferry's key from a
/// signed feed. A menu-bar app that opens at login rarely quits, so once an update is ready the
/// menu offers to restart into it (L15).
@MainActor
final class SparkleUpdates: UpdateChecking {
  private let controller: SPUStandardUpdaterController
  /// Sparkle keeps its delegate weakly.
  private let readyUpdate: ReadyUpdate

  /// `nil`, and Sparkle never starts, when the build has no feed or no release key (see
  /// `UpdateFeed`). `ready` runs once Sparkle holds a downloaded update for the next quit.
  init?(bundle: Bundle = .main, ready: @escaping @MainActor () -> Void) {
    guard UpdateFeed(info: bundle.infoDictionary ?? [:]) != nil else { return nil }
    readyUpdate = ReadyUpdate(ready: ready)
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: readyUpdate, userDriverDelegate: nil)
    // Ferry has no switch for this: a choice an earlier version saved does not turn it off.
    controller.updater.automaticallyChecksForUpdates = true
    controller.updater.automaticallyDownloadsUpdates = true
  }

  func checkForUpdates() {
    NSApp.activate()
    controller.checkForUpdates(nil)
  }

  func installUpdateAndRelaunch() {
    readyUpdate.install()
  }
}

/// Takes the update Sparkle scheduled for the next quit, so the menu can install it now.
///
/// Returning true from `willInstallUpdateOnQuit` hands Sparkle's install handler to Ferry, and
/// Sparkle's header says that stalls further update cycles until then; it still installs the
/// update when Ferry quits, as before.
@MainActor
private final class ReadyUpdate: NSObject, SPUUpdaterDelegate {
  private let ready: @MainActor () -> Void
  private var installNow: (() -> Void)?

  init(ready: @escaping @MainActor () -> Void) {
    self.ready = ready
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    installNow = immediateInstallHandler
    ready()
    return true
  }

  /// Installs the update and relaunches Ferry. Sparkle 2.3 and later accept the handler again if
  /// the quit it starts is cancelled.
  func install() {
    installNow?()
  }
}
