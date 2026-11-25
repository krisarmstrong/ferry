import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

// MARK: Identifiers the system holds and the table lost

extension DomainController {
  /// The first wait before asking again for a reimport the system refused; it doubles to 60 s.
  static let reimportRetry = Duration.seconds(2)

  /// The system named, as the place for a new item, a folder of `domain` that the table never
  /// knew in this agent's run (one it forgot is a deletion, answered "no such item"). An earlier
  /// agent re-minted the identifiers, and the folder's parents are likely lost too: "no such
  /// item" would have the system re-create those folders by name, into ones the device already
  /// has (`NSFileProviderReplicatedExtension.h`, createItem's error cases). So the system is
  /// asked to import the domain's items again (each comes back as a create that may already
  /// exist, which the extension matches to the device's item), and asked again with back-off
  /// until it accepts.
  ///
  /// Returns whether this request started the reimport, and so is to be retried after it. Every
  /// later one, while it is under way or once it is done, is "no such item": a folder still
  /// unknown after a reimport is gone, and FileProvider must not be held off forever.
  func identifiersLost(_ domain: String) -> Bool {
    guard reimported[domain] == nil else { return false }
    reimported[domain] = false
    log.error("domain \(domain, privacy: .private) holds identifiers the agent lost; reimporting")
    reimportTasks[domain] = requestFreeTask { [weak self, clock] in
      var delay = Self.reimportRetry
      while let asked = await self?.askToReimport(domain), !asked {
        do {
          try await clock.sleep(for: delay)
        } catch {
          return
        }
        delay = min(delay * 2, .seconds(60))
      }
    }
    return true
  }

  /// Asks the system to reimport `domain`; `nil` once there is nothing to ask for (the domain
  /// was removed, or Remove Ferry ran).
  private func askToReimport(_ domain: String) async -> Bool? {
    guard !retired, domains[domain] != nil else {
      reimportTasks[domain] = nil
      return nil
    }
    do {
      try await manager.reimport(domain)
    } catch {
      log.error(
        "reimporting \(domain, privacy: .private) failed: \(error, privacy: .private)")
      return false
    }
    reimported[domain] = true
    reimportTasks[domain] = nil
    return true
  }
}
