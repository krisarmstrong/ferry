import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// Finder shows a domain only while it is connected: a device that is away is hidden, never
/// removed, so its files and unsent changes stay for when it is back.
extension DomainController {
  /// Hides each domain not connected and shows each connected one, where the system's state
  /// differs: a hide or show that failed is tried again on every reconcile.
  func showOnlyConnected() async {
    for (identifier, domain) in domains.sorted(by: { $0.key < $1.key })
    where domain.hidden == domain.connected {
      await setHidden(identifier, !domain.connected)
    }
  }

  func setHidden(_ identifier: String, _ hidden: Bool) async {
    do {
      try await manager.setHidden(identifier, hidden: hidden)
      domains[identifier]?.hidden = hidden
    } catch {
      log.error(
        "\(hidden ? "hiding" : "showing") domain \(identifier, privacy: .private) failed: \(error, privacy: .private)"
      )
    }
  }
}
