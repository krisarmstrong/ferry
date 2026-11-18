import DeviceKit
import Foundation

/// The storages ADB serves: the user storages MTP exposes, not the whole filesystem. Keys are
/// method-neutral (see `StorageKey`) so an MTP storage maps onto the same one.
enum ADBStorages {
  static let internalRoot = "/storage/emulated/0"
  static let internalDescription = "Internal shared storage"
  static let volumeDescription = "Removable storage"
  static let volumesFolder = "/storage"

  struct Space: Equatable {
    let capacity: UInt64
    let free: UInt64
  }

  /// The device folder a storage key names; `nil` for a key that is not an ADB storage.
  static func root(forKey key: String) -> String? {
    if key == StorageKey.internal { return internalRoot }
    return StorageKey.volumeID(of: key).map { volumesFolder + "/" + $0 }
  }

  /// Capacity and free bytes from `df -k`. The figures are found by their shape, three counts
  /// then a percentage, so neither the filesystem name nor a wrapped line can shift them.
  static func space(fromDF output: String) -> Space? {
    let fields = output.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 4 else { return nil }
    for start in 0...(fields.count - 4) {
      let percent = fields[start + 3]
      guard let total = UInt64(fields[start]), UInt64(fields[start + 1]) != nil,
        let available = UInt64(fields[start + 2]), percent.last == "%",
        UInt64(percent.dropLast()) != nil
      else { continue }
      return Space(capacity: kilobytes(total), free: kilobytes(available))
    }
    return nil
  }

  private static func kilobytes(_ count: UInt64) -> UInt64 {
    let (bytes, overflow) = count.multipliedReportingOverflow(by: 1024)
    return overflow ? .max : bytes
  }
}

// MARK: Discovery

extension ADBSession {
  /// Internal shared storage and each volume in `/storage`, sized by `df`. A storage `df` cannot
  /// size (it went away meanwhile) is left out; none at all is for the caller to judge.
  func discoverStorages() async throws(TransportError) -> [StorageInfo] {
    let step = Step("reading storages", .root)
    var candidates: [(key: String, description: String)] = []
    let internalStat = try await adb(step) { () async throws(ADBError) in
      try await syncing { (sync) async throws(ADBError) in
        try await sync.stat(ADBStorages.internalRoot)
      }
    }
    if internalStat?.isDirectory == true {
      candidates.append((StorageKey.internal, ADBStorages.internalDescription))
    }
    let volumes = try await adb(step) { () async throws(ADBError) in
      try await syncing { (sync) async throws(ADBError) in
        try await sync.list(ADBStorages.volumesFolder)
      }
    }
    for entry in volumes.entries.sorted(by: { $0.name < $1.name })
    where entry.stat.isDirectory && StorageKey.isVolumeID(entry.name) {
      candidates.append((StorageKey.volume(entry.name), ADBStorages.volumeDescription))
    }

    var storages: [StorageInfo] = []
    for candidate in candidates {
      guard let root = ADBStorages.root(forKey: candidate.key) else { continue }
      let result = try await run("df", ["-k", "--", root], step)
      guard result.status == 0,
        let space = ADBStorages.space(fromDF: String(bytes: result.stdout, encoding: .utf8) ?? "")
      else {
        Self.log.info("leaving out storage \(candidate.key, privacy: .private): df failed")
        continue
      }
      storages.append(
        StorageInfo(
          id: StorageID(device: info.id, key: candidate.key), description: candidate.description,
          capacity: space.capacity, free: space.free))
    }
    return storages
  }
}
