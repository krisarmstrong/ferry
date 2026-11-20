import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// Finder shows a domain only while it is connected: a device that is away is hidden, never
/// removed, so its files and unsent changes stay for when it is back.
extension DomainController {
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
    for (identifier, domain) in domains.sorted(by: { $0.key < $1.key })
    where systemHidden.map({ $0.contains(identifier) == domain.connected }) ?? true {
      await setHidden(identifier, !domain.connected)
    }
  }

  func setHidden(_ identifier: String, _ hidden: Bool) async {
    do {
      try await manager.setHidden(identifier, hidden: hidden)
    } catch {
      log.error(
        "\(hidden ? "hiding" : "showing") domain \(identifier, privacy: .private) failed: \(error, privacy: .private)"
      )
    }
  }
}
