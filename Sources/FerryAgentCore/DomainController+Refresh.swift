import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

extension DomainController {
  /// Lists again every folder the device's connected domains know, so files added, changed or
  /// removed on the device are recorded in each domain's change log, and signals each domain
  /// that changed. FileProvider learns of changes made outside Finder only this way. The session
  /// first forgets what it remembers of the device's items (MTP reopens the device), so a file
  /// an app rewrote in place shows its new size and date.
  func refresh(_ device: DeviceID) async throws(TransportError) {
    let identifiers = connectedDomains(of: device)
    guard !identifiers.isEmpty else { return }
    let lease = try await leaseSession(of: device)
    let forgotten: Result<Void, TransportError>
    do throws(TransportError) {
      try await lease.session.forgetCachedItems()
      forgotten = .success(())
    } catch {
      forgotten = .failure(error)
    }
    await hub.release(lease)
    try forgotten.get()
    for identifier in identifiers {
      try await refreshDomain(identifier)
    }
  }

  /// Lists the domain's known folders again (see `relistKnownFolders(of:)`) and signals the
  /// domain if anything changed, even on a failure.
  func refreshDomain(_ identifier: String) async throws(TransportError) {
    let (changed, failure) = await relistKnownFolders(of: identifier)
    if changed {
      await signal(identifier)
    }
    if let failure { throw failure }
  }

  /// Lists the domain's known folders again, parents first, one turn of its gate each, so
  /// requests interleave. A folder a parent's listing showed gone is skipped; one the device no
  /// longer has is forgotten. Stops at the first other failure. Returns whether anything was
  /// recorded, and the failure.
  func relistKnownFolders(of identifier: String) async -> (
    changed: Bool, failure: TransportError?
  ) {
    await relistFolders(nil, of: identifier)
  }

  /// Lists `folders` of the domain again, or every folder it knows for `nil`, parents first, as
  /// `relistKnownFolders(of:)` does.
  func relistFolders(_ folders: [RemotePath]?, of identifier: String) async -> (
    changed: Bool, failure: TransportError?
  ) {
    let route: Route
    do throws(TransportError) {
      route = try await self.route(identifier)
    } catch {
      return (false, error)
    }
    let before = await route.items.changeCount
    var failure: TransportError?
    let listing: [RemotePath]
    if let folders {
      listing = Self.parentsFirst(folders)
    } else {
      listing = await route.items.knownFolders()
    }
    for folder in listing {
      do throws(TransportError) {
        try await relist(folder, on: route)
      } catch {
        log.error(
          "refreshing \(identifier, privacy: .private) failed: \(String(describing: error), privacy: .private)"
        )
        failure = error
        break
      }
    }
    await route.release()
    return (await route.items.changeCount != before, failure)
  }

  static func parentsFirst(_ folders: [RemotePath]) -> [RemotePath] {
    folders.sorted {
      ($0.components.count, $0.description) < ($1.components.count, $1.description)
    }
  }

  private func relist(_ folder: RemotePath, on route: Route) async throws(TransportError) {
    try await route.items.gate.run { () async throws(TransportError) in
      guard await route.items.knows(folder) else { return }
      do throws(TransportError) {
        let items = try await route.writer.visibleList(folder, in: route.storage)
        _ = await route.items.listed(folder, children: items)
      } catch .notFound {
        await route.items.removed(folder)
      }
    }
  }
}
