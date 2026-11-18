import DeviceKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "StorageAliases")

/// Which volume each removable storage MTP knows only by its description is, per device.
///
/// Android's MTP server sends no volume ID, so MTP keys an SD card `"<description>|"`, the same
/// for every card of a vendor, while ADB serves it as `volume:<ID>`. A match is made only from
/// two readings of one attachment (the controller forgets a device's last reading when it
/// leaves): the device's one MTP card and its one ADB volume, of the same capacity to the KiB.
/// It is applied only to an MTP card of that capacity, so another card does not take the
/// matched card's Finder location; one that differs is served under its description. When the
/// device is seen both ways with its matched volume absent and one other volume of the card's
/// capacity, the match moves to that volume. When in doubt nothing is matched: a card with a
/// location per method is acceptable, writing to the wrong card is not.
///
/// Two cards of one capacity cannot be told apart over MTP; such a card is served in the matched
/// card's location until the device is seen over ADB.
///
/// Kept in the agent's item store, beside the item tables, and removed with them.
struct StorageAliases: Sendable, Equatable {
  struct Match: Codable, Sendable, Equatable {
    let volume: String
    /// The card's capacity in KiB: MTP's `MaxCapacity` and ADB's `df` total, both from the
    /// filesystem, agree to the KiB.
    let capacity: UInt64
  }

  /// Serial → MTP key → match.
  private(set) var matches: [String: [String: Match]] = [:]

  static let fileName = "storage-aliases.plist"

  static func kibibytes(_ bytes: UInt64) -> UInt64 { bytes / 1024 }

  /// The storage whose domain `storage` uses: the volume its card was matched to, if it is that
  /// card's capacity, or itself.
  func identity(of storage: StorageInfo) -> StorageID {
    let id = storage.id
    guard let match = matches[id.device.serial]?[id.key],
      match.capacity == Self.kibibytes(storage.capacity)
    else { return id }
    return StorageID(device: id.device, key: match.volume)
  }

  /// The MTP keys matched to the volume `identity`, whose own domains it superseded.
  func mtpKeys(of identity: StorageID) -> [String] {
    (matches[identity.device.serial] ?? [:]).filter { $0.value.volume == identity.key }.keys
      .sorted()
  }

  /// Matches the device's one MTP card to its one ADB volume of the same capacity, from two
  /// readings of one attachment. Returns whether anything changed, and the volume a replaced
  /// match had, whose domain the caller retires.
  mutating func learn(_ device: DeviceID, mtp: [StorageInfo], adb: [StorageInfo]) -> (
    changed: Bool, replaced: String?
  ) {
    let cards = mtp.filter {
      $0.id.key != StorageKey.internal && StorageKey.volumeID(of: $0.id.key) == nil
    }
    guard cards.count == 1 else { return (false, nil) }
    let card = cards[0]
    let capacity = Self.kibibytes(card.capacity)
    let known = matches[device.serial] ?? [:]
    let volumes = adb.filter { StorageKey.volumeID(of: $0.id.key) != nil }
    if let match = known[card.id.key], volumes.contains(where: { $0.id.key == match.volume }) {
      return (false, nil)
    }
    // A volume another card's match names stays that card's while that card is the one here.
    let claimed = Set(
      known.filter { $0.key != card.id.key && $0.value.capacity != capacity }.map(\.value.volume))
    let candidates = volumes.filter {
      Self.kibibytes($0.capacity) == capacity && !claimed.contains($0.id.key)
    }
    guard candidates.count == 1 else { return (false, nil) }
    let volume = candidates[0].id.key
    let replaced = known[card.id.key].map(\.volume).flatMap { $0 == volume ? nil : $0 }
    var updated = known.filter { $0.value.volume != volume }
    updated[card.id.key] = Match(volume: volume, capacity: capacity)
    matches[device.serial] = updated
    return (true, replaced)
  }

  static func load(from store: URL) -> StorageAliases {
    let file = store.appending(path: fileName)
    do {
      let data = try Data(contentsOf: file)
      let matches = try PropertyListDecoder().decode(
        [String: [String: Match]].self, from: data)
      return StorageAliases(matches: matches)
    } catch CocoaError.fileReadNoSuchFile {
      return StorageAliases()
    } catch {
      log.error("reading storage aliases failed: \(error, privacy: .private)")
      return StorageAliases()
    }
  }

  func save(to store: URL) {
    do {
      try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
      let data = try PropertyListEncoder().encode(matches)
      try data.write(to: store.appending(path: Self.fileName), options: .atomic)
    } catch {
      log.error("saving storage aliases failed: \(error, privacy: .private)")
    }
  }

  static func discard(in store: URL) {
    ItemTable.remove(store.appending(path: fileName))
  }
}
