import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

extension DomainController {
  /// Keeps `vouching` told of the Finder locations Ferry has: now, if the domains from before
  /// this process are adopted, and after every change to them from then on.
  public func publishLocations(to vouching: WirelessVouching) {
    locationListener = vouching
    if adopted { publishLocations() }
  }

  func publishLocations() {
    locationListener?.locate(
      identifiers: Set(domains.keys), devices: Set(domains.values.compactMap(\.storage?.device)),
      complete: locationsComplete)
  }

  /// The first delay before listing the system's domains again after a failure; it doubles to
  /// a minute.
  static let listingRetry = Duration.seconds(2)

  /// Lists the system's domains again, with back-off, until it works, then publishes the
  /// complete set. Meanwhile the set is published as incomplete, so nothing unvouched is served
  /// and every device counts as possibly located. Remove Ferry ends it.
  func retryListing() {
    listingRetryTask = requestFreeTask { [weak self, clock] in
      var delay = Self.listingRetry
      while true {
        do {
          try await clock.sleep(for: delay)
        } catch {
          return
        }
        guard let listed = await self?.listAgain(), !listed else { return }
        delay = min(delay * 2, .seconds(60))
      }
    }
  }

  /// Whether the system's domains could be listed and adopted; `nil` once Remove Ferry has run,
  /// which leaves nothing to adopt. Checked in the operation queue, after which nothing can
  /// retire the controller before the adoption.
  private func listAgain() async -> Bool? {
    let listed = await serially { () async -> Bool? in
      guard await !self.retired else { return nil }
      return await self.adoptExisting()
    }
    if listed == true {
      locationsComplete = true
      publishLocations()
    }
    return listed
  }

  /// The name of the Finder location Ferry has for `id`, connected or not, or `nil` if it has
  /// none: a device with a location is one Ferry knows even while it is unplugged.
  ///
  /// A domain this process added or served names its storage. One adopted at start is known only
  /// by its identifier, a SHA-256 of `"<serial>|<key>"`, so the claimed serial is hashed with
  /// the key of internal storage, `internal`, which every Android device has under either
  /// method. Card keys (a volume UUID,
  /// or an MTP description with a volume ID) cannot be guessed, but a card's domain never exists
  /// without its device's internal one, so they add nothing. Domains carry no other record of
  /// their storage key to check.
  ///
  /// It waits until the domains from before this process are adopted. While they could not be
  /// listed, any device may have a location Ferry cannot see, so every device not otherwise found
  /// counts as located, named by its serial.
  public func location(of id: DeviceID) async -> String? {
    if !adopted {
      await withCheckedContinuation { adoptionWaiters.append($0) }
    }
    if let match = domains.values.first(where: { $0.storage?.device == id }) {
      return match.spec?.displayName ?? id.serial
    }
    let identifier = DomainNaming.identifier(for: StorageID(device: id, key: StorageKey.internal))
    guard domains[identifier] != nil else { return locationsComplete ? nil : id.serial }
    return await manager.displayName(of: identifier) ?? id.serial
  }

  /// Records the system's domains as disconnected and hides them, so a ready device reconnects
  /// and shows its domain rather than adding it again. One named by serial, as an earlier Ferry
  /// did, is removed first (keeping unsent changes) with its item table. Returns whether the
  /// domains could be listed and every one named by serial removed: false leaves the location
  /// set incomplete, and `retryListing()` tries again.
  func adoptExisting() async -> Bool {
    let identifiers: [String]
    do {
      identifiers = try await manager.existing()
    } catch {
      log.error("listing existing domains failed: \(error, privacy: .private)")
      return false
    }
    // A domain this Ferry does not name could be any device's: until it is gone the location
    // set cannot be complete, so no unvouched network route is served, and the retry removes it
    // again. Removing keeps unsent changes, as an eject does.
    var unknownOwnerLeft = false
    for identifier in identifiers.filter({ !DomainNaming.isIdentifier($0) }).sorted() {
      ItemTable.discard(domain: identifier, in: itemStore)
      do {
        _ = try await manager.remove(identifier)
      } catch {
        log.error(
          "removing domain \(identifier, privacy: .private) failed: \(error, privacy: .private)")
        unknownOwnerLeft = true
      }
    }
    let adopted = identifiers.filter { DomainNaming.isIdentifier($0) && domains[$0] == nil }
      .sorted()
    for identifier in adopted {
      domains[identifier] = Domain(spec: nil, storage: nil, connected: true)
    }
    for identifier in adopted {
      await disconnect(identifier)
    }
    return !unknownOwnerLeft
  }
}
