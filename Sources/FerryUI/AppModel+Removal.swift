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

  /// The Help topic that holds Remove Ferry…, which the menu's Option alternative opens.
  nonisolated static let removeFerryHelpTopic = "remove-ferry"

  /// The menu's Remove Ferry…: opens its Help topic, which confirms and shows any failure.
  public func showRemoveFerry() {
    showHelp(topic: Self.removeFerryHelpTopic)
  }

  /// Removes Ferry's locations from Finder, unregisters the agent, moves Ferry's data to the Trash and stops
  /// its own adb server once the agent has exited, forgets that Ferry ran here (so a reinstall
  /// shows the welcome), unregisters the login item, and quits.
  ///
  /// The agent removes the locations, so it stops serving them first. When it cannot, or has not
  /// answered within `removalAgentWait` (it is the problem people remove Ferry for), the agent
  /// is unregistered first, so it adds none back, and the app removes the locations itself. An
  /// agent macOS never registered cannot be unregistered, which matters only while one still
  /// runs. Stops if the
  /// locations or a running agent remain, so the user can try again rather than being left
  /// with locations no agent serves. Once the agent is gone a retry could only fail, so a login
  /// item that will not unregister is logged and Ferry quits anyway. Changes the locations had
  /// not sent to a device are shown in Finder, since the menu goes away.
  public func removeFerry() async {
    removalError = nil
    // The agent is about to be unregistered: a status lost meanwhile must not restart it.
    removing = true
    let preserved: [URL]
    do {
      let saved: [URL]
      if let removed = try await locationsRemovedByTheAgent() {
        saved = removed
        try await unregisterTheAgent()
      } else {
        try await unregisterTheAgent()
        saved = try await services.removeFileProviderDomains()
      }
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
            "Could not remove Ferry. Try again; if it keeps failing, restart the Mac and try again.",
            bundle: .module))
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

  /// How long Remove Ferry waits for the agent to remove the locations before the app does.
  /// The agent waits for running transfers first, so it is generous.
  static let removalAgentWait = Duration.seconds(60)

  /// Has the agent remove every Ferry location; returns where unsent changes were saved, or
  /// `nil` when it did not answer, failed or took longer than `removalAgentWait`. An app
  /// replaced by an update throws instead: the new agent refuses it, and the new app removes
  /// Ferry.
  private func locationsRemovedByTheAgent() async throws -> [URL]? {
    let reply = await withTaskGroup(of: AgentResponse?.self) { group in
      group.addTask { try? await self.client.send(.removeAllDomains, file: nil) }
      group.addTask {
        try? await self.sleep(Self.removalAgentWait)
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
    if case .removed(let saved)? = reply { return saved }
    Self.log.error("the agent did not remove the locations")
    if services.appWasReplaced() { throw TransportError.io("app replaced by an update") }
    return nil
  }

  /// Unregisters the agent. One macOS never registered cannot be, which matters only while an
  /// agent process still runs.
  private func unregisterTheAgent() async throws {
    do {
      try await services.unregisterAgent()
    } catch {
      guard await !services.agentIsRunning() else { throw error }
      Self.log.error("unregistering the agent failed: \(error, privacy: .private)")
    }
  }
}
