import FerryAgentCore
import FileProvider
import os

private let log = Logger(
  subsystem: "io.github.krisarmstrong.ferry", category: "FileProviderDomains")

/// The system's FileProvider domains for Ferry, through `NSFileProviderManager`.
struct FileProviderDomains: DomainManaging {
  func add(_ spec: DomainSpec) async throws {
    try await NSFileProviderManager.add(
      Self.configured(
        NSFileProviderDomainIdentifier(spec.identifier), displayName: spec.displayName))
  }

  /// Adds every existing domain again whose settings differ from `configured`, such as one
  /// added by an earlier Ferry. An add with an existing identifier updates the domain in place,
  /// so its items, enablement and the agent's item table all stay.
  func conformExisting() async {
    let domains: [NSFileProviderDomain]
    do {
      domains = try await NSFileProviderManager.domains()
    } catch {
      log.error("listing domains failed: \(error, privacy: .public)")
      return
    }
    for domain in domains where domain.supportsSyncingTrash {
      do {
        try await NSFileProviderManager.add(
          Self.configured(domain.identifier, displayName: domain.displayName))
        log.info("updated settings of \(domain.identifier.rawValue, privacy: .private)")
      } catch {
        log.error(
          "updating \(domain.identifier.rawValue, privacy: .private) failed: \(error, privacy: .public)"
        )
      }
    }
  }

  private static func configured(
    _ identifier: NSFileProviderDomainIdentifier, displayName: String
  ) -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
    // MTP has no trash: Finder offers Delete Immediately, which deletes on the device.
    domain.supportsSyncingTrash = false
    return domain
  }

  func disconnect(_ identifier: String) async throws {
    // Not `.temporary`: the domain stays disconnected until the agent sees its device again.
    try await manager(identifier).disconnect(
      reason: String(localized: "Connect the device and choose Transfer files to see its files."),
      options: [])
  }

  func reconnect(_ identifier: String) async throws {
    try await manager(identifier).reconnect()
  }

  func remove(_ identifier: String) async throws {
    try await NSFileProviderManager.remove(try await domain(identifier))
  }

  func removeAll() async throws {
    try await NSFileProviderManager.removeAllDomains()
  }

  func signal(_ identifier: String) async {
    do {
      try await manager(identifier).signalEnumerator(for: .workingSet)
    } catch {
      log.error(
        "signalling \(identifier, privacy: .private) failed: \(error, privacy: .public)")
    }
  }

  func isUserEnabled() async -> Bool {
    do {
      return try await NSFileProviderManager.domains().contains(where: \.userEnabled)
    } catch {
      log.error("listing domains failed: \(error, privacy: .public)")
      return false
    }
  }

  func existing() async throws -> [String] {
    try await NSFileProviderManager.domains().map(\.identifier.rawValue)
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
