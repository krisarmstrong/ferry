import Foundation

/// `StorageID.key` for each storage, by raw storage ID.
///
/// The key is `"<StorageDescription>|<VolumeIdentifier>"`, which survives reconnects while the
/// raw ID may not. When that pair says nothing (empty, NULL, or libmtp's placeholders for a
/// device without GetStorageInfo) or two storages share it, the affected keys also carry the
/// raw ID as `|#XXXXXXXX` so they stay distinct.
func storageKeys(for storages: [RawStorage]) -> [UInt32: String] {
  let base = storages.map { "\($0.description ?? "")|\($0.volume ?? "")" }
  var counts: [String: Int] = [:]
  for key in base {
    counts[key, default: 0] += 1
  }
  var keys: [UInt32: String] = [:]
  for (storage, key) in zip(storages, base) {
    let uninformative =
      isBlank(storage.description, placeholder: "Unknown storage")
      && isBlank(storage.volume, placeholder: "Unknown volume")
    let ambiguous = uninformative || counts[key, default: 0] > 1
    keys[storage.raw] = ambiguous ? key + "|#" + String(format: "%08X", storage.raw) : key
  }
  return keys
}

/// A storage as libmtp describes it, before it gets a `StorageID`.
struct RawStorage: Equatable {
  let raw: UInt32
  let description: String?
  let volume: String?
}

private func isBlank(_ value: String?, placeholder: String) -> Bool {
  guard let value else { return true }
  return value.isEmpty || value == placeholder
}
