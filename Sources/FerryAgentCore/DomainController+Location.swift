import DeviceKit

extension DomainController {
  /// The keys internal storage has had: ADB's and MTP's since Task 5, and the MTP description an
  /// earlier Ferry used.
  static let internalKeys = [StorageKey.internal, DomainNaming.androidInternalDescription]

  /// Keeps `vouching` told of the Finder locations Ferry has: now, if the domains from before
  /// this process are adopted, and after every change to them from then on.
  public func publishLocations(to vouching: WirelessVouching) {
    locationListener = vouching
    if adopted { publishLocations() }
  }

  func publishLocations() {
    locationListener?.locate(
      identifiers: Set(domains.keys), devices: Set(domains.values.compactMap(\.storage?.device)))
  }

  /// The name of the Finder location Ferry has for `id`, connected or not, or `nil` if it has
  /// none: a device with a location is one Ferry knows even while it is unplugged.
  ///
  /// A domain this process added or served names its storage. One adopted at start is known only
  /// by its identifier, a SHA-256 of `"<serial>|<key>"`, so the claimed serial is hashed with
  /// the keys of internal storage: `internal`, which every Android device has under either
  /// method, and the MTP description key an earlier Ferry used for it. Card keys (a volume UUID,
  /// or an MTP description with a volume ID) cannot be guessed, but a card's domain never exists
  /// without its device's internal one, so they add nothing. Domains carry no other record of
  /// their storage key to check.
  public func location(of id: DeviceID) async -> String? {
    if let match = domains.values.first(where: { $0.storage?.device == id }) {
      return match.spec?.displayName ?? id.serial
    }
    let candidates = Self.internalKeys.map {
      DomainNaming.identifier(for: StorageID(device: id, key: $0))
    }
    guard let identifier = candidates.first(where: { domains[$0] != nil }) else { return nil }
    return await manager.displayName(of: identifier) ?? id.serial
  }
}
