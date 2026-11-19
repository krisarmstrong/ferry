import DeviceKit

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
  /// and every device counts as possibly located.
  func retryListing() {
    Task {
      var delay = Self.listingRetry
      while !retired {
        guard (try? await Task.sleep(for: delay)) != nil else { return }
        if await serially({ await self.adoptExisting() }) {
          locationsComplete = true
          publishLocations()
          return
        }
        delay = min(delay * 2, .seconds(60))
      }
    }
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
}
