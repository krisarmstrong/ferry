import DeviceKit
import FerryIPC
import Foundation

/// Remove Ferry, and what the app does once an update replaced it while it ran.
extension AppModel {
  /// What the menu and Help say once the agent refuses this copy after an update.
  static var replacedMessage: String {
    String(
      localized: LocalizedStringResource(
        "Ferry was updated. Quit and reopen Ferry.", bundle: .module))
  }

  /// Relaunch: opens the updated Ferry and quits this copy.
  public func relaunch() {
    services.relaunch()
  }

  /// Help opened: Remove Ferry… starts afresh, without a failure from an earlier attempt.
  public func helpAppeared() {
    removalError = nil
  }

  /// Removes Ferry's locations from Finder, unregisters the agent, moves Ferry's data to the Trash and stops
  /// its own adb server once the agent has exited, forgets that Ferry ran here (so a reinstall
  /// shows the welcome), unregisters the login item, and quits. Stops
  /// if the locations or the agent remain, so the user can try again rather than being left
  /// with locations no agent serves. Once the agent is gone a retry could only fail, so a login
  /// item that will not unregister is logged and Ferry quits anyway. Changes the
  /// locations had not sent to a device are shown in Finder, since the menu goes away.
  public func removeFerry() async {
    removalError = nil
    // The agent is about to be unregistered: a status lost meanwhile must not restart it.
    removing = true
    let preserved: [URL]
    do {
      guard case .removed(let saved) = try await client.send(.removeAllDomains, file: nil) else {
        throw TransportError.io("agent kept its locations")
      }
      try await services.unregisterAgent()
      // Once the agent has exited, so it cannot write its tables or devices back.
      await services.removeFerryData(keeping: saved)
      // So a reinstall is a first run, with the welcome.
      services.forgetFirstRun()
      preserved = saved.filter(Self.holdsSomething)
    } catch {
      Self.log.error("removing Ferry failed: \(String(describing: error), privacy: .private)")
      removing = false
      if services.appWasReplaced() {
        agent = .replaced
        removalError = Self.replacedMessage
      } else {
        removalError = String(
          localized: LocalizedStringResource(
            "Could not remove Ferry. Make sure Ferry is running, then try again.", bundle: .module))
      }
      return
    }
    if !preserved.isEmpty {
      services.reveal(preserved)
    }
    if await services.loginItemStatus() != .disabled {
      do {
        try await services.setOpensAtLogin(false)
      } catch {
        Self.log.error("removing the login item failed: \(error, privacy: .private)")
      }
    }
    services.quit()
  }
}
