import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

// MARK: Identifiers the system holds and the table lost

extension DomainController {
  /// The system named a folder of `domain` that the table does not know as the place for a new
  /// item. Its parent chain is likely lost too (an earlier agent re-minted the identifiers), and
  /// "no such item" alone would have the system re-create those folders by name, into ones the
  /// device already has. So the system is asked, once per domain while this agent runs, to import
  /// the domain's items again; each comes back as a create that may already exist, which the
  /// extension matches to the device's item and its identifier now.
  func identifiersLost(_ domain: String) async {
    guard reimported.insert(domain).inserted else { return }
    log.error("domain \(domain, privacy: .private) holds identifiers the agent lost; reimporting")
    await manager.reimport(domain)
  }
}
