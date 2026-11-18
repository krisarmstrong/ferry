import DeviceKit
import Foundation

/// `StorageID.key` for each storage, by raw storage ID.
///
/// Storages ADB can also serve get its method-neutral keys (see `StorageKey`), so a device keeps
/// its Finder locations whichever method serves it:
/// - Android's primary shared storage is always storage `0x00010001`, a fixed one, whatever its
///   description says (that is in the device's language): `internal`.
/// - A storage whose volume identifier is a filesystem ID (`XXXX-XXXX` or a UUID) is the volume
///   ADB finds at `/storage/<ID>`: `volume:<ID>`. Android's own MTP server sends an empty volume
///   identifier, so its SD cards do not match and only MTP serves them.
///
/// Every other storage is keyed `"<StorageDescription>|<VolumeIdentifier>"`, which survives
/// reconnects while the raw ID may not. When that pair says nothing (empty, NULL, or libmtp's
/// placeholders for a device without GetStorageInfo) or two storages share it, the affected keys
/// also carry the raw ID as `|#XXXXXXXX` so they stay distinct. Two storages claiming one volume
/// are keyed this way too.
func storageKeys(for storages: [RawStorage]) -> [UInt32: String] {
  let neutral = storages.map(neutralKey)
  var neutralCounts: [String: Int] = [:]
  for key in neutral.compactMap({ $0 }) {
    neutralCounts[key, default: 0] += 1
  }
  let base = storages.map { "\($0.description ?? "")|\($0.volume ?? "")" }
  var counts: [String: Int] = [:]
  for key in base {
    counts[key, default: 0] += 1
  }
  var keys: [UInt32: String] = [:]
  for (storage, (key, neutral)) in zip(storages, zip(base, neutral)) {
    if let neutral, neutralCounts[neutral] == 1 {
      keys[storage.raw] = neutral
      continue
    }
    let uninformative =
      isBlank(storage.description, placeholder: "Unknown storage")
      && isBlank(storage.volume, placeholder: "Unknown volume")
    let ambiguous = uninformative || counts[key, default: 0] > 1 || neutral != nil
    keys[storage.raw] = ambiguous ? key + "|#" + String(format: "%08X", storage.raw) : key
  }
  return keys
}

/// Android's storage ID for its primary shared storage (`StorageVolume.STORAGE_ID_PRIMARY`).
private let androidPrimaryStorage: UInt32 = 0x0001_0001
/// PTP StorageType codes for fixed storage.
private let fixedStorageTypes: Set<UInt16> = [0x0001, 0x0003]

private func neutralKey(_ storage: RawStorage) -> String? {
  if storage.raw == androidPrimaryStorage, fixedStorageTypes.contains(storage.type) {
    return StorageKey.internal
  }
  if let volume = storage.volume, StorageKey.isVolumeID(volume) {
    return StorageKey.volume(volume)
  }
  return nil
}

/// A storage as libmtp describes it, before it gets a `StorageID`.
struct RawStorage: Equatable {
  let raw: UInt32
  let description: String?
  let volume: String?
  /// PTP's FilesystemType code.
  var fileSystem: UInt16 = 0
  /// PTP's StorageType code.
  var type: UInt16 = 0
}

private func isBlank(_ value: String?, placeholder: String) -> Bool {
  guard let value else { return true }
  return value.isEmpty || value == placeholder
}
