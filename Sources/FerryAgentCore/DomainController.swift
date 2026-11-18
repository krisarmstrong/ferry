import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// The system's FileProvider domains. The agent's implementation wraps `NSFileProviderManager`.
public protocol DomainManaging: Sendable {
  /// Adds the domain, or renames it if one with the same identifier exists.
  func add(_ spec: DomainSpec) async throws
  func disconnect(_ identifier: String) async throws
  func reconnect(_ identifier: String) async throws
  /// Removes the domain, keeping changes not yet sent to the device, and returns where they were
  /// saved, if there were any.
  func remove(_ identifier: String) async throws -> URL?
  /// Removes every Ferry domain the same way, and returns where unsent changes were saved.
  func removeAll() async throws -> [URL]
  /// Tells the system the domain's working set changed. A replicated FileProvider extension
  /// ignores signals for any other container; it then asks the agent for `.changes`.
  func signal(_ identifier: String) async
  /// Whether the user has enabled Ferry's domains, or none exists yet. New domains start disabled
  /// and only the user can enable them, so `.disabled` is a normal state.
  func providerState() async -> ProviderState
  /// The identifiers of the Ferry domains the system has, including ones from before this
  /// process started.
  func existing() async throws -> [String]
}

/// Keeps one FileProvider domain per storage of each ready device, and maps a domain back to
/// the session that serves it: the hub's current one, leased for the request, so the hub can
/// change how it reaches the device (MTP or ADB) between requests without touching the domain.
///
/// A domain is added the first time its storage is ready. When the device leaves (unplugged,
/// locked, not sharing files, failed) its domains are disconnected, never removed, so a replug
/// reconnects the same domain. Only `eject` and `removeAll` remove domains.
///
/// At start, every domain the system already has (from before an agent restart) is disconnected
/// until its device is ready again. After `removeAll` the controller adds nothing more, so Remove
/// Ferry leaves no domain behind however long the agent takes to stop.
///
/// Each domain has one `ItemTable`, loaded from the store when first used. It outlives a
/// disconnect and an agent restart, so Finder's items keep their identity across both; removing
/// the domain discards it.
public actor DomainController {
  /// What a request on a domain runs against. Holds a lease on the device's session until
  /// `release()`, which every route must get.
  struct Route: Sendable {
    let storage: StorageID
    let session: any DeviceSession
    /// A writer over `session`. Every writer over a session shares its in-flight registry.
    let writer: SafeWriter
    /// The domain's one item table.
    let items: ItemTable
    fileprivate let lease: SessionLease
    fileprivate let hub: DeviceHub

    func release() async {
      await hub.release(lease)
    }
  }

  private struct Domain {
    /// `nil` for a domain found at start, until its device is ready and names it.
    var spec: DomainSpec?
    var storage: StorageID?
    var connected: Bool
  }

  let hub: DeviceHub
  private let manager: any DomainManaging
  private let itemStore: URL
  private var domains: [String: Domain] = [:]
  /// The item table of each domain used since it was added or adopted.
  private var tables: [String: ItemTable] = [:]
  /// The operation most recently queued; the next one waits for it.
  private var tail: Task<Void, Never>?
  /// Devices whose eject is closing their session. Their domains are gone and must not come
  /// back from a device list read before the hub marked them ejected.
  private var ejecting: Set<DeviceID> = []
  /// Set by `removeAll`: no domain is added, reconnected or disconnected afterwards.
  private var retired = false
  /// Hub events handled so far.
  private(set) var handledEvents = 0
  /// Set once the domains from before this process are adopted, whether or not listing them
  /// worked; until then requests wait (see `route(_:)`).
  private var adopted = false
  private var adoptionWaiters: [CheckedContinuation<Void, Never>] = []
  /// Requests waiting for the domains from before this process to be adopted.
  var requestsAwaitingAdoption: Int { adoptionWaiters.count }

  /// `itemStore` is the folder holding the item tables, one file per domain. It must be the
  /// agent's own: the sandboxed extension can write to the app group's container.
  public init(hub: DeviceHub, manager: any DomainManaging, itemStore: URL) {
    self.hub = hub
    self.manager = manager
    self.itemStore = itemStore
  }

  /// The agent's item store, in its own Application Support folder.
  public static func defaultItemStore() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "io.github.krisarmstrong.ferry.agent/items", directoryHint: .isDirectory)
  }

  /// Follows the hub until the calling task is cancelled. Call it once: it is the only consumer
  /// of the hub's events.
  public func run() async {
    await serially { await self.adoptExisting() }
    adopted = true
    for waiter in adoptionWaiters {
      waiter.resume()
    }
    adoptionWaiters = []
    for await event in hub.events {
      await serially { await self.handle(event) }
      handledEvents += 1
    }
  }

  /// Removes the device's domains, then closes its session, and returns where unsent changes
  /// were saved. The device stays listed as ejected until it is unplugged or mounted. A transfer
  /// in progress on the device finishes before the close, since the session runs its operations
  /// one at a time; the close is awaited outside the operation queue, so other devices' domains
  /// keep updating meanwhile.
  func eject(_ id: DeviceID) async -> [URL] {
    let preserved = await serially { await self.removeDomains(of: id) }
    await hub.eject(id)
    ejecting.remove(id)
    return preserved
  }

  /// Removes every Ferry domain, including ones this process never added, and returns where
  /// unsent changes were saved.
  func removeAll() async throws(TransportError) -> [URL] {
    try await serially({ await self.removeEveryDomain() }).get()
  }

  /// What a request on `domain` runs against. Waits until the domains from before this process
  /// are adopted. A domain that is unknown, not adopted or not connected is `.deviceDisconnected`,
  /// which FileProvider retries: anything it reads as "no such item" would make it delete the
  /// domain's items locally, and a request can arrive before an agent restart's adoption.
  func route(_ domain: String) async throws(TransportError) -> Route {
    let (storage, items) = try await connected(domain)
    let lease = try await leaseSession(of: storage.device)
    return Route(
      storage: storage, session: lease.session, writer: SafeWriter(session: lease.session),
      items: items, lease: lease, hub: hub)
  }

  /// The domain's item table, for a request that does not touch the device. Waits, and fails,
  /// as `route(_:)` does.
  func items(of domain: String) async throws(TransportError) -> ItemTable {
    try await connected(domain).items
  }

  private func connected(_ domain: String) async throws(TransportError) -> (
    storage: StorageID, items: ItemTable
  ) {
    if !adopted {
      await withCheckedContinuation { adoptionWaiters.append($0) }
    }
    guard let entry = domains[domain], entry.connected, let storage = entry.storage else {
      throw .deviceDisconnected
    }
    return (storage, table(for: domain))
  }

  func signal(_ domain: String) async {
    await manager.signal(domain)
  }

  /// The connected domains of `device`, in identifier order.
  func connectedDomains(of device: DeviceID) -> [String] {
    domains.filter { $0.value.connected && $0.value.storage?.device == device }.keys.sorted()
  }

  func providerState() async -> ProviderState {
    await manager.providerState()
  }

  /// The domain's table, loaded on first use. Nothing awaits between the lookup and the insert,
  /// so a domain never has two.
  private func table(for domain: String) -> ItemTable {
    if let table = tables[domain] { return table }
    let table = ItemTable(domain: domain, store: itemStore)
    tables[domain] = table
    return table
  }

  /// Deletes the domain's table, loaded or not, so a domain added again starts with new
  /// identifiers.
  private func discardTable(of domain: String) async {
    if let table = tables.removeValue(forKey: domain) {
      await table.discard()
    } else {
      ItemTable.discard(domain: domain, in: itemStore)
    }
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

  /// Records the system's domains as disconnected, so a ready device reconnects its domain
  /// rather than adding it again, and an absent device's domain does not look live. A domain
  /// named the way an earlier Ferry named them, by serial, is removed first (keeping unsent
  /// changes) with its item table; its storage comes back under its new identifier once ready.
  private func adoptExisting() async {
    let identifiers: [String]
    do {
      identifiers = try await manager.existing()
    } catch {
      log.error("listing existing domains failed: \(error, privacy: .private)")
      return
    }
    for identifier in identifiers.filter({ !DomainNaming.isIdentifier($0) }).sorted() {
      ItemTable.discard(domain: identifier, in: itemStore)
      _ = await remove(identifier)
    }
    let adopted = identifiers.filter { DomainNaming.isIdentifier($0) && domains[$0] == nil }
      .sorted()
    for identifier in adopted {
      domains[identifier] = Domain(spec: nil, storage: nil, connected: true)
    }
    for identifier in adopted {
      await disconnect(identifier)
    }
  }

  private func handle(_ event: HubEvent) async {
    guard !retired else { return }
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
    for (spec, storage) in wanted where !ejecting.contains(storage.device) {
      await connect(spec, storage)
    }
  }

  private func connect(_ spec: DomainSpec, _ storage: StorageID) async {
    let identifier = spec.identifier
    guard var existing = domains[identifier] else {
      guard await isServed(storage.device) else { return }
      domains[identifier] = Domain(spec: spec, storage: storage, connected: true)
      do {
        try await manager.add(spec)
      } catch {
        log.error(
          "adding domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
        domains[identifier] = nil
      }
      return
    }
    if existing.storage == nil {
      // Found at start: its device is ready now, so it takes this spec without a rename.
      existing.storage = storage
      existing.spec = spec
      domains[identifier] = existing
    }
    if !existing.connected {
      guard await isServed(storage.device) else { return }
      domains[identifier]?.connected = true
      do {
        try await manager.reconnect(identifier)
      } catch {
        log.error(
          "reconnecting domain \(identifier, privacy: .private) failed: \(error, privacy: .private)"
        )
        domains[identifier]?.connected = false
        return
      }
      // The device may have changed while it was away, so the folders Finder knows are listed
      // again first. FileProvider asks for changes only when signalled. An anchor from before the
      // disconnect may be stale (a new agent process expires every old anchor), so it asks now
      // and enumerates again if the anchor expired.
      _ = await relistKnownFolders(of: identifier)
      await manager.signal(identifier)
    }
    if existing.spec != spec {
      domains[identifier]?.spec = spec
      do {
        try await manager.add(spec)
      } catch {
        log.error(
          "renaming domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
        domains[identifier]?.spec = existing.spec
      }
    }
  }

  private func disconnectDomains(of id: DeviceID) async {
    let connected = domains.filter { $0.value.connected && $0.value.storage?.device == id }
    for identifier in connected.keys.sorted() {
      await disconnect(identifier)
    }
  }

  private func disconnect(_ identifier: String) async {
    guard let domain = domains[identifier], domain.connected else { return }
    domains[identifier]?.connected = false
    do {
      try await manager.disconnect(identifier)
    } catch {
      log.error(
        "disconnecting domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
    }
  }

}

// MARK: Removing

extension DomainController {
  private func removeDomains(of id: DeviceID) async -> [URL] {
    ejecting.insert(id)
    let identifiers = domains.filter { $0.value.storage?.device == id }.keys.sorted()
    for identifier in identifiers {
      domains[identifier] = nil
    }
    var preserved: [URL] = []
    for identifier in identifiers {
      await discardTable(of: identifier)
      if let location = await remove(identifier) { preserved.append(location) }
    }
    return preserved
  }

  /// Removes one domain, keeping its unsent changes; a failure is logged.
  private func remove(_ identifier: String) async -> URL? {
    do {
      let preserved = try await manager.remove(identifier)
      if let preserved {
        log.info(
          "removed domain \(identifier, privacy: .private) kept unsent changes in \(preserved.path, privacy: .private)"
        )
      } else {
        log.info("removed domain \(identifier, privacy: .private); nothing unsent")
      }
      return preserved
    } catch {
      log.error(
        "removing domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
      return nil
    }
  }

  private func removeEveryDomain() async -> Result<[URL], TransportError> {
    retired = true
    domains = [:]
    for table in tables.values {
      await table.discard()
    }
    tables = [:]
    ItemTable.discardAll(in: itemStore)
    do {
      return .success(try await manager.removeAll())
    } catch {
      log.error("removing all domains failed: \(error, privacy: .private)")
      return .failure(.io("could not remove domains"))
    }
  }
}
