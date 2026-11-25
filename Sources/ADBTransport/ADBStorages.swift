import DeviceKit
import Foundation

/// The storages ADB serves: the user storages MTP exposes, not the whole filesystem. Keys are
/// method-neutral (see `StorageKey`) so an MTP storage maps onto the same one.
enum ADBStorages {
  static let internalRoot = "/storage/emulated/0"
  static let internalDescription = "Internal shared storage"
  static let volumeDescription = "Removable storage"
  static let volumesFolder = "/storage"
  /// `file` on a device with file-based encryption, whose shared storage is credential
  /// encrypted (CE): until the user first unlocks after a restart, its names read as ciphertext.
  static let cryptoTypeProperty = "ro.crypto.type"
  /// `true` once the system has unlocked user 0's CE storage, whose `/storage/emulated/0` Ferry
  /// serves.
  static let credentialStorageProperty = "sys.user.0.ce_available"
  /// Folders shared storage has once in use, any one of which listed by name shows it unlocked.
  static let wellKnownFolders: Set<String> = ["Android", "Download", "DCIM"]

  /// Whether `names` read as fscrypt ciphertext, as a locked storage lists them: base64 of at
  /// least 16 bytes (22 characters or more) in fscrypt's alphabet, which uses `+` and `,`.
  static func lookEncrypted(_ names: [String]) -> Bool {
    !names.isEmpty
      && names.allSatisfy { name in
        name.utf8.count >= 22
          && name.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
              || $0 == "+" || $0 == ","
          }
      }
  }

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
      // Locked, the folder is there but lists ciphertext names: serving it would read as every
      // item deleted and new ones made, and the device is locked as surely as when it shows no
      // storage at all.
      if try await credentialStorageLocked(step) { throw .deviceLocked }
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

  /// Whether internal shared storage is credential encrypted and not unlocked yet. A device
  /// without file-based encryption never is; one with it is unlocked once the system says so.
  /// A device that does not say (the property empty, or `getprop` failing) is judged by what
  /// the storage lists: locked only if its names look encrypted and none is a folder shared
  /// storage has once in use, so an odd property never locks a device out for good.
  private func credentialStorageLocked(_ step: Step) async throws(TransportError) -> Bool {
    guard !credentialStorageReadable else { return false }
    var unlocked = try await property(ADBStorages.cryptoTypeProperty, step) != "file"
    if !unlocked {
      unlocked = try await property(ADBStorages.credentialStorageProperty, step) == "true"
    }
    if unlocked {
      credentialStorageReadable = true
      return false
    }
    let listing = try await adb(step) { () async throws(ADBError) in
      try await syncing { (sync) async throws(ADBError) in
        try await sync.list(ADBStorages.internalRoot)
      }
    }
    let names = listing.entries.map(\.name)
    if !ADBStorages.wellKnownFolders.isDisjoint(with: names) {
      credentialStorageReadable = true
      return false
    }
    return ADBStorages.lookEncrypted(names)
  }

  private func property(_ name: String, _ step: Step) async throws(TransportError) -> String {
    let result = try await run("getprop", [name], step)
    guard result.status == 0 else { return "" }
    return String(bytes: result.stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
