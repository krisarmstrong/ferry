import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// The system's FileProvider domains. The agent's implementation wraps `NSFileProviderManager`.
public protocol DomainManaging: Sendable {
  /// Adds the domain, or renames it if one with the same identifier exists.
  func add(_ spec: DomainSpec) async throws
  func disconnect(_ identifier: String) async throws
  func reconnect(_ identifier: String) async throws
  func remove(_ identifier: String) async throws
  func removeAll() async throws
  /// Tells the system the folder's contents changed.
  func signal(_ identifier: String, folder: RemotePath) async
  /// Whether the user has enabled Ferry's domains. New domains start disabled and only the user
  /// can enable them, so `false` is a normal state.
  func isUserEnabled() async -> Bool
}

/// Keeps one FileProvider domain per storage of each ready device, and maps a domain back to
/// the session that serves it.
///
/// A domain is added the first time its storage is ready. When the device leaves (unplugged,
/// locked, not sharing files, failed) its domains are disconnected, never removed, so a replug
/// reconnects the same domain. Only `eject` and `removeAll` remove domains.
public actor DomainController {
  /// What a request on a domain runs against.
  struct Route: Sendable {
    let storage: StorageID
    let session: any DeviceSession
    /// The one writer over `session`, so every upload shares one in-flight registry.
    let writer: SafeWriter
  }

  private struct Domain {
    var spec: DomainSpec
    let storage: StorageID
    var connected: Bool
  }

  private struct Link {
    let session: any DeviceSession
    let writer: SafeWriter
  }

  private let hub: DeviceHub
  private let manager: any DomainManaging
  private var domains: [String: Domain] = [:]
  /// The held session of each device with a connected domain.
  private var links: [DeviceID: Link] = [:]
  /// The operation most recently queued; the next one waits for it.
  private var tail: Task<Void, Never>?

  public init(hub: DeviceHub, manager: any DomainManaging) {
    self.hub = hub
    self.manager = manager
  }

  /// Follows the hub until the calling task is cancelled. Call it once: it is the only consumer
  /// of the hub's events.
  public func run() async {
    for await event in hub.events {
      await serially { await self.handle(event) }
    }
  }

  /// Removes the device's domains, then closes its session. The device stays listed as not
  /// sharing files until it is unplugged. A transfer in progress on the device finishes first,
  /// since the session runs its operations one at a time.
  func eject(_ id: DeviceID) async {
    await serially { await self.removeDomains(of: id) }
  }

  /// Removes every Ferry domain, including ones this process never added.
  func removeAll() async throws(TransportError) {
    if let failure = await serially({ await self.removeEveryDomain() }) {
      throw failure
    }
  }

  func route(_ domain: String) throws(TransportError) -> Route {
    guard let entry = domains[domain] else { throw .storageNotFound(domain) }
    guard entry.connected, let link = links[entry.storage.device] else {
      throw .deviceDisconnected
    }
    return Route(storage: entry.storage, session: link.session, writer: link.writer)
  }

  func signal(_ domain: String, folder: RemotePath) async {
    await manager.signal(domain, folder: folder)
  }

  func isUserEnabled() async -> Bool {
    await manager.isUserEnabled()
  }

  // MARK: Operations

  /// Runs operations one at a time, in the order they were asked for, so an eject cannot
  /// interleave with a reconcile that read the device list before it. Every change to `domains`
  /// and `links` happens inside one of these operations.
  private func serially<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
    let previous = tail
    let current = Task {
      await previous?.value
      return await work()
    }
    tail = Task { _ = await current.value }
    return await current.value
  }

  private func handle(_ event: HubEvent) async {
    // A device that left is disconnected here even if it is back by the time the list is read,
    // so its old session is never kept for the new one.
    switch event {
    case .detached(let id):
      await disconnectDomains(of: id)
    case .attached(let device), .changed(let device):
      if case .ready = device.state { break }
      await disconnectDomains(of: device.id)
    }
    await reconcile()
  }

  private func reconcile() async {
    let wanted = DomainNaming.domains(for: await hub.devices())
    let live = Set(wanted.map(\.spec.identifier))
    for (identifier, domain) in domains where domain.connected && !live.contains(identifier) {
      await disconnect(identifier)
    }
    for (spec, storage) in wanted {
      await connect(spec, storage)
    }
  }

  private func connect(_ spec: DomainSpec, _ storage: StorageID) async {
    let identifier = spec.identifier
    guard let existing = domains[identifier] else {
      guard await link(for: storage.device) != nil else { return }
      domains[identifier] = Domain(spec: spec, storage: storage, connected: true)
      do {
        try await manager.add(spec)
      } catch {
        log.error(
          "adding domain \(identifier, privacy: .private) failed: \(error, privacy: .public)")
        domains[identifier] = nil
      }
      return
    }
    if !existing.connected {
      guard await link(for: storage.device) != nil else { return }
      domains[identifier]?.connected = true
      do {
        try await manager.reconnect(identifier)
      } catch {
        log.error(
          "reconnecting domain \(identifier, privacy: .private) failed: \(error, privacy: .public)")
        domains[identifier]?.connected = false
        return
      }
    }
    if existing.spec != spec {
      domains[identifier]?.spec = spec
      do {
        try await manager.add(spec)
      } catch {
        log.error(
          "renaming domain \(identifier, privacy: .private) failed: \(error, privacy: .public)")
        domains[identifier]?.spec = existing.spec
      }
    }
  }

  /// The device's link, opening one over the hub's session if there is none.
  private func link(for id: DeviceID) async -> Link? {
    if let link = links[id] { return link }
    let session: any DeviceSession
    do throws(TransportError) {
      session = try await hub.session(for: id)
    } catch {
      log.error(
        "no session for \(id.serial, privacy: .private): \(String(describing: error), privacy: .public)"
      )
      return nil
    }
    let link = Link(session: session, writer: SafeWriter(session: session))
    links[id] = link
    return link
  }

  private func disconnectDomains(of id: DeviceID) async {
    links[id] = nil
    let connected = domains.filter { $0.value.connected && $0.value.storage.device == id }
    for identifier in connected.keys.sorted() {
      await disconnect(identifier)
    }
  }

  private func disconnect(_ identifier: String) async {
    guard let domain = domains[identifier], domain.connected else { return }
    domains[identifier]?.connected = false
    let device = domain.storage.device
    if !domains.values.contains(where: { $0.connected && $0.storage.device == device }) {
      links[device] = nil
    }
    do {
      try await manager.disconnect(identifier)
    } catch {
      log.error(
        "disconnecting domain \(identifier, privacy: .private) failed: \(error, privacy: .public)")
    }
  }

  private func removeDomains(of id: DeviceID) async {
    links[id] = nil
    let identifiers = domains.filter { $0.value.storage.device == id }.keys.sorted()
    for identifier in identifiers {
      domains[identifier] = nil
    }
    for identifier in identifiers {
      do {
        try await manager.remove(identifier)
      } catch {
        log.error(
          "removing domain \(identifier, privacy: .private) failed: \(error, privacy: .public)")
      }
    }
    await hub.eject(id)
  }

  private func removeEveryDomain() async -> TransportError? {
    domains = [:]
    links = [:]
    do {
      try await manager.removeAll()
      return nil
    } catch {
      log.error("removing all domains failed: \(error, privacy: .public)")
      return .io("could not remove domains")
    }
  }
}
