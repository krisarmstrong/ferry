import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

extension DomainController {
  /// Lists again every folder the device's connected domains know, so files added, changed or
  /// removed on the device are recorded in each domain's change log, and signals each domain
  /// that changed. FileProvider learns of changes made outside Finder only this way.
  func refresh(_ device: DeviceID) async throws(TransportError) {
    for identifier in connectedDomains(of: device) {
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
    let route: Route
    do throws(TransportError) {
      route = try await self.route(identifier)
    } catch {
      return (false, error)
    }
    let before = await route.items.changeCount
    var failure: TransportError?
    for folder in await route.items.knownFolders() {
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
