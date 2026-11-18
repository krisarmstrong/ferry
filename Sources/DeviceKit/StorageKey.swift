import Foundation

/// Method-neutral `StorageID.key`s, so one storage keeps its key, and its Finder location, whether
/// MTP or ADB serves it.
public enum StorageKey {
  /// Android's primary shared storage, `/storage/emulated/0` over ADB.
  public static let `internal` = "internal"
  private static let volumePrefix = "volume:"

  /// A removable volume, `/storage/<id>` over ADB. The ID takes Android's case for its mount
  /// folder (upper case for FAT's `XXXX-XXXX`, lower case for a UUID), so an ID MTP reports in
  /// the other case gets the same key.
  public static func volume(_ id: String) -> String {
    volumePrefix + (UUID(uuidString: id) != nil ? id.lowercased() : id.uppercased())
  }

  /// The volume ID a `volume(_:)` key names, or `nil` for any other key.
  public static func volumeID(of key: String) -> String? {
    guard key.hasPrefix(volumePrefix) else { return nil }
    let id = String(key.dropFirst(volumePrefix.count))
    return isVolumeID(id) ? id : nil
  }

  /// Whether `name` is a volume's filesystem ID as Android names its mount folder: `XXXX-XXXX`
  /// for FAT and exFAT, a UUID for others. `emulated`, `self` and legacy names are not.
  public static func isVolumeID(_ name: String) -> Bool {
    if UUID(uuidString: name) != nil { return true }
    let halves = name.split(separator: "-", omittingEmptySubsequences: false)
    return halves.count == 2 && halves.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) }
  }
}
