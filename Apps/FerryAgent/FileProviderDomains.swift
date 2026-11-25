import FerryAgentCore
import FerryIPC
import FileProvider
import os

private let log = Logger(
  subsystem: "io.github.krisarmstrong.ferry", category: "FileProviderDomains")

/// The system's FileProvider domains for Ferry, through `NSFileProviderManager`.
struct FileProviderDomains: DomainManaging {
  func add(_ spec: DomainSpec) async throws {
    try await NSFileProviderManager.add(
      DomainSettings.configured(spec.identifier, displayName: spec.displayName))
  }

  /// Adds every existing domain again whose settings differ from Ferry's (`DomainSettings`),
  /// such as one added by an earlier Ferry. An add with an existing identifier updates the domain in place,
  /// so its items, enablement and the agent's item table all stay; it also sets whether the
  /// domain is hidden, so the domain keeps the state it has. A domain named by serial is left
  /// alone: `DomainController` replaces it.
  func conformExisting() async {
    let domains: [NSFileProviderDomain]
    do {
      domains = try await NSFileProviderManager.domains()
    } catch {
      log.error("listing domains failed: \(error, privacy: .private)")
      return
    }
    for domain in domains where DomainSettings.needsUpdate(domain) {
      do {
        try await NSFileProviderManager.add(
          DomainSettings.configured(
            domain.identifier.rawValue, displayName: domain.displayName, hidden: domain.isHidden))
        log.info("updated settings of \(domain.identifier.rawValue, privacy: .private)")
      } catch {
        log.error(
          "updating \(domain.identifier.rawValue, privacy: .private) failed: \(error, privacy: .private)"
        )
      }
    }
  }

  func disconnect(_ identifier: String) async throws {
    // Not `.temporary`: the domain stays disconnected until the agent sees its device again.
    try await manager(identifier).disconnect(
      reason: String(localized: AgentText.disconnected),
      options: [])
  }

  func reconnect(_ identifier: String) async throws {
    try await manager(identifier).reconnect()
  }

  /// An add with the domain's identifier and display name: `NSFileProviderManager.h` says an add
  /// for an existing identifier updates the display name and hidden state and succeeds, so the
  /// domain is not replaced and its replicated files and unsent changes stay. It is made even when
  /// the listing already shows the state, which may lag an add just made. A domain the system
  /// does not list is not added: that would bring back one ejected or removed.
  func setHidden(_ identifier: String, hidden: Bool) async throws {
    let domain = try await domain(identifier)
    try await NSFileProviderManager.add(
      DomainSettings.configured(identifier, displayName: domain.displayName, hidden: hidden))
  }

  /// `.preserveDirtyUserData`: changes not yet uploaded are moved aside rather than discarded.
  func remove(_ identifier: String) async throws -> URL? {
    try await NSFileProviderManager.remove(
      try await domain(identifier), mode: .preserveDirtyUserData)
  }

  /// Removes each domain as `remove` does. Tries every one, then throws the first failure.
  func removeAll() async throws -> [URL] {
    var preserved: [URL] = []
    var failure: (any Error)?
    for domain in try await NSFileProviderManager.domains() {
      do {
        let location = try await NSFileProviderManager.remove(
          domain, mode: .preserveDirtyUserData)
        preserved += location.map { [$0] } ?? []
      } catch {
        log.error(
          "removing \(domain.identifier.rawValue, privacy: .private) failed: \(error, privacy: .private)"
        )
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
    return preserved
  }

  func signal(_ identifier: String) async {
    do {
      try await manager(identifier).signalEnumerator(for: .workingSet)
    } catch {
      log.error(
        "signalling \(identifier, privacy: .private) failed: \(error, privacy: .private)")
    }
  }

  func lockResolved(_ identifier: String) async {
    do {
      try await manager(identifier).signalErrorResolved(NSFileProviderError(.notAuthenticated))
    } catch {
      log.error(
        "resolving the lock of \(identifier, privacy: .private) failed: \(error, privacy: .private)"
      )
    }
  }

  func reachable(_ identifier: String) async {
    do {
      try await manager(identifier).signalErrorResolved(NSFileProviderError(.serverUnreachable))
    } catch {
      log.error(
        "resolving unreachable for \(identifier, privacy: .private) failed: \(error, privacy: .private)"
      )
    }
  }

  /// From the root: the lost identifiers include every folder above the one a request named, so
  /// nothing smaller would match items to the device. The system rebuilds the domain's store
  /// and may stop the extension meanwhile; local changes not yet sent come back as creates.
  func reimport(_ identifier: String) async throws {
    try await manager(identifier).reimportItems(below: .rootContainer)
  }

  /// A failed listing reads as no domains: the menu then asks nothing of the user.
  func providerState() async -> ProviderState {
    do {
      return ProviderState(
        domains: try await NSFileProviderManager.domains().map {
          (enabled: $0.userEnabled, hidden: $0.isHidden)
        })
    } catch {
      log.error("listing domains failed: \(error, privacy: .private)")
      return .noDomains
    }
  }

  func hiddenDomains() async throws -> Set<String> {
    Set(try await NSFileProviderManager.domains().filter(\.isHidden).map(\.identifier.rawValue))
  }

  /// The domain's pending set holds anything (see `PendingProbe`), asked for at most 2 s.
  func hasUnsentChanges(_ identifier: String) async -> Bool {
    let manager: NSFileProviderManager
    do {
      manager = try await self.manager(identifier)
    } catch {
      log.error(
        "no manager for \(identifier, privacy: .private): \(error, privacy: .private)")
      return false
    }
    let enumerator = manager.enumeratorForPendingItems()
    defer { enumerator.invalidate() }
    return await PendingProbe.anyItem(in: enumerator, within: .seconds(2))
  }

  func existing() async throws -> [String] {
    try await NSFileProviderManager.domains().map(\.identifier.rawValue)
  }

  func displayName(of identifier: String) async -> String? {
    try? await domain(identifier).displayName
  }

  /// The registered domain, which carries the display name a manager needs.
  private func domain(_ identifier: String) async throws -> NSFileProviderDomain {
    let wanted = NSFileProviderDomainIdentifier(identifier)
    guard
      let domain = try await NSFileProviderManager.domains().first(where: {
        $0.identifier == wanted
      })
    else {
      throw NSFileProviderError(.providerDomainNotFound)
    }
    return domain
  }

  private func manager(_ identifier: String) async throws -> NSFileProviderManager {
    guard let manager = NSFileProviderManager(for: try await domain(identifier)) else {
      throw NSFileProviderError(.providerDomainNotFound)
    }
    return manager
  }
}
