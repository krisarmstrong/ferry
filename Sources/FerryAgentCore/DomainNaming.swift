import CryptoKit
import DeviceKit
import Foundation

/// One FileProvider domain: a single storage of one device.
public struct DomainSpec: Sendable, Hashable {
  /// See `DomainNaming.identifier(for:)`. Never parsed back: the agent maps it to its storage in
  /// memory.
  public let identifier: String
  public let displayName: String

  public init(identifier: String, displayName: String) {
    self.identifier = identifier
    self.displayName = displayName
  }
}

public enum DomainNaming {
  struct Wanted {
    let spec: DomainSpec
    /// The storage as the session serving it names it.
    let storage: StorageID
    /// Keys the storage's domain was named by before, whose domains it supersedes.
    let formers: [StorageID]
  }

  /// What MTP calls Android's primary storage, in English: the key ADB's `internal` had when
  /// MTP keyed storages by description. A device served over ADB from the start has no MTP
  /// reading to say so, so its old domain is found by this.
  static let androidInternalDescription = "Internal shared storage|"

  /// The domain identifier of a storage: SHA-256, in lowercase hex, of `"<serial>|<key>"`.
  /// Stable across reconnects, and free of the serial, which FileProvider would otherwise write
  /// to its logs and to the paths of the domain's files.
  public static func identifier(for storage: StorageID) -> String {
    SHA256.hash(data: Data("\(storage.device.serial)|\(storage.key)".utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  /// Whether `string` has the form `identifier(for:)` gives. A Ferry domain whose identifier does
  /// not is from an earlier Ferry that named domains by serial.
  public static func isIdentifier(_ string: String) -> Bool {
    string.utf8.count == 64
      && string.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  /// A spec for each storage of each ready device, in order.
  ///
  /// A domain is named after its device (`DeviceInfo.name`), with the end of its serial added
  /// when another listed device has the same name (see `DeviceNames`), as the menus name it,
  /// and ` – SD card` added for every storage after the device's first.
  public static func specs(for devices: [AttachedDevice]) -> [DomainSpec] {
    domains(for: devices).map(\.spec)
  }

  /// Each wanted domain with the storage that serves it, and the keys it was named by before.
  ///
  /// An SD card is never matched across methods: MTP knows it only by its description, which
  /// every card of a vendor shares, and ADB by its volume ID. It has a location per method, so
  /// another card can never take a card's location.
  static func domains(for devices: [AttachedDevice]) -> [Wanted] {
    let suffixes = DeviceNames.suffixes(for: devices.map { ($0.id, $0.info.name) })
    return devices.flatMap { device -> [Wanted] in
      guard case .ready(let storages) = device.state else { return [] }
      let base = DeviceNames.named(device.info.name, suffix: suffixes[device.id])
      return storages.enumerated().map { index, storage in
        let spec = DomainSpec(
          identifier: identifier(for: storage.id),
          displayName: index == 0 ? base : base + " – SD card")
        var formers = [storage.formerKey].compactMap { $0 }
        if storage.id.key == StorageKey.internal {
          formers.append(androidInternalDescription)
        }
        let superseded = Set(formers).subtracting([storage.id.key]).sorted()
        return Wanted(
          spec: spec, storage: storage.id,
          formers: superseded.map { StorageID(device: device.id, key: $0) })
      }
    }
  }
}
