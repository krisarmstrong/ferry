import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// Finder shows a domain only while it is connected: a device that is away is hidden, never
/// removed, so its files and unsent changes stay for when it is back.
extension DomainController {
  /// The first wait before trying a failed hide or show again; it doubles to a minute.
  static let visibilityRetry = Duration.seconds(2)

  /// Hides each domain not connected and shows each connected one, where the system's own
  /// state differs, so a difference heals whatever caused it: a hide or show that failed, or the
  /// system changing it. While the system's hidden domains cannot be listed, every domain is set
  /// again; setting a state a domain already has changes nothing.
  func showOnlyConnected() async {
    let systemHidden: Set<String>?
    do {
      systemHidden = try await manager.hiddenDomains()
    } catch {
      log.error("listing hidden domains failed: \(error, privacy: .private)")
      systemHidden = nil
    }
    if let systemHidden {
      // For checking a dev build: `log stream --level debug --predicate 'subsystem ==
      // "io.github.krisarmstrong.ferry" AND category == "DomainController"'`.
      let listed = systemHidden.sorted().joined(separator: " ")
      log.debug(
        "reconcile: \(systemHidden.count, privacy: .public) hidden domains: \(listed, privacy: .private)"
      )
    }
    var failed = systemHidden == nil
    for (identifier, domain) in domains.sorted(by: { $0.key < $1.key })
    where systemHidden.map({ $0.contains(identifier) == domain.connected }) ?? true {
      if !(await setHidden(identifier, !domain.connected)) { failed = true }
    }
    if failed {
      scheduleVisibilityRetry()
    } else {
      visibilityRetryDelay = nil
    }
  }

  /// Whether the system took the request. A failure schedules a retry.
  @discardableResult func setHidden(_ identifier: String, _ hidden: Bool) async -> Bool {
    do {
      try await manager.setHidden(identifier, hidden: hidden)
      return true
    } catch {
      let change = hidden ? "hiding" : "showing"
      log.error(
        """
        \(change, privacy: .public) domain \(identifier, privacy: .private) failed: \
        \(error, privacy: .private)
        """)
      scheduleVisibilityRetry()
      return false
    }
  }

  /// Mends every domain's visibility after a wait, unless a retry is already waiting: so a
  /// failure heals even when no device comes or goes to start a reconcile.
  private func scheduleVisibilityRetry() {
    guard visibilityRetryTask == nil, !retired else { return }
    let delay = visibilityRetryDelay.map { min($0 * 2, .seconds(60)) } ?? Self.visibilityRetry
    visibilityRetryDelay = delay
    visibilityRetryTask = requestFreeTask { [weak self, clock] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      await self?.retryVisibility()
    }
  }

  private func retryVisibility() async {
    visibilityRetryTask = nil
    await serially {
      guard await !self.retired else { return }
      await self.showOnlyConnected()
    }
  }

  /// Reconnects a domain just added, which may be one the system had disconnected. If that
  /// fails it counts as not connected, so the mend that ends the reconcile hides it.
  func reconnectAdded(_ identifier: String) async {
    do {
      try await manager.reconnect(identifier)
    } catch {
      log.error(
        "reconnecting domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
      domains[identifier]?.connected = false
    }
  }

  /// The names of the locations whose device is away, so they are hidden, that still hold
  /// changes not sent to the device, in name order. Finder shows pending files only in a shown
  /// location, so the menu names these instead. A location from before the agent started has
  /// the name the system shows for it.
  public func locationsWaitingToSend() async -> [String] {
    let away = domains.filter { !$0.value.connected }.map { ($0.key, $0.value.spec?.displayName) }
    var names: [String] = []
    for (identifier, known) in away {
      guard await manager.hasUnsentChanges(identifier) else { continue }
      if let name = known, !name.isEmpty {
        names.append(name)
      } else if let name = await manager.displayName(of: identifier) {
        names.append(name)
      }
    }
    return names.sorted()
  }
}
