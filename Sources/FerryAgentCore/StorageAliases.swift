import DeviceKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "StorageAliases")

/// Which volume each removable storage MTP knows only by its description is, per device.
///
/// Android's MTP server sends no volume ID, so MTP keys an SD card `"<description>|"` while ADB
/// serves it as `volume:<ID>`. The first time a device is seen both ways, its one unmatched MTP
/// storage and its one unmatched ADB volume are taken to be the same card, and the card keeps the
/// volume's domain whichever method serves it. With more than one unmatched storage on either
/// side nothing is guessed: those cards keep a domain per method.
///
/// Kept in the agent's item store, beside the item tables, and removed with them.
struct StorageAliases: Sendable, Equatable {
  /// Serial → MTP key → volume key.
  private(set) var volumes: [String: [String: String]] = [:]

  static let fileName = "storage-aliases.plist"

  /// The storage whose domain `storage` uses: the volume an MTP card was matched to, or itself.
  func identity(of storage: StorageID) -> StorageID {
    guard let volume = volumes[storage.device.serial]?[storage.key] else { return storage }
    return StorageID(device: storage.device, key: volume)
  }

  /// The MTP keys matched to the volume `identity`, whose own domains it superseded.
  func mtpKeys(of identity: StorageID) -> [String] {
    (volumes[identity.device.serial] ?? [:]).filter { $0.value == identity.key }.keys.sorted()
  }

  /// Matches the device's one unmatched MTP storage to its one unmatched ADB volume. Returns
  /// whether anything was learnt.
  mutating func learn(_ device: DeviceID, mtp: [StorageInfo], adb: [StorageInfo]) -> Bool {
    let known = volumes[device.serial] ?? [:]
    let cards = mtp.map(\.id.key).filter { key in
      key != StorageKey.internal && StorageKey.volumeID(of: key) == nil && known[key] == nil
    }
    let matched = Set(known.values)
    let volumeKeys = adb.map(\.id.key).filter {
      StorageKey.volumeID(of: $0) != nil && !matched.contains($0)
    }
    guard cards.count == 1, volumeKeys.count == 1 else { return false }
    volumes[device.serial, default: [:]][cards[0]] = volumeKeys[0]
    return true
  }

  static func load(from store: URL) -> StorageAliases {
    let file = store.appending(path: fileName)
    do {
      let data = try Data(contentsOf: file)
      let volumes = try PropertyListDecoder().decode([String: [String: String]].self, from: data)
      return StorageAliases(volumes: volumes)
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
      let data = try PropertyListEncoder().encode(volumes)
      try data.write(to: store.appending(path: Self.fileName), options: .atomic)
    } catch {
      log.error("saving storage aliases failed: \(error, privacy: .private)")
    }
  }

  static func discard(in store: URL) {
    ItemTable.remove(store.appending(path: fileName))
  }
}
