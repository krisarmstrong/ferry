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

  /// Removes Ferry's locations from Finder, unregisters the agent and the login item, and
  /// quits. Stops if the locations or the agent remain, so the user can try again rather than
  /// being left with locations no agent serves. Once the agent is gone a retry could only fail,
  /// so a login item that will not unregister is logged and Ferry quits anyway. Changes the
  /// locations had not sent to a device are shown in Finder, since the menu goes away.
  public func removeFerry() async {
    removalError = nil
    let preserved: [URL]
    do {
      guard case .removed(let saved) = try await client.send(.removeAllDomains, file: nil) else {
        throw TransportError.io("agent kept its locations")
      }
      try await services.unregisterAgent()
      preserved = saved.filter(Self.holdsSomething)
    } catch {
      Self.log.error("removing Ferry failed: \(String(describing: error), privacy: .private)")
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
    if await services.opensAtLogin() {
      do {
        try await services.setOpensAtLogin(false)
      } catch {
        Self.log.error("removing the login item failed: \(error, privacy: .public)")
      }
    }
    services.quit()
  }
}
