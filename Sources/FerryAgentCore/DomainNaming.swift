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
  /// A domain is named after its device's model, with the last four characters of the serial
  /// added when another listed device has the same model, and ` – SD card` added for every
  /// storage after the device's first.
  public static func specs(for devices: [AttachedDevice]) -> [DomainSpec] {
    domains(for: devices, aliases: StorageAliases()).map(\.spec)
  }

  /// Each wanted domain with the storage that serves it. A card MTP knows by description is
  /// named for the volume `aliases` matched it to.
  static func domains(for devices: [AttachedDevice], aliases: StorageAliases) -> [Wanted] {
    var models: [String: Int] = [:]
    for device in devices {
      models[device.info.model, default: 0] += 1
    }
    return devices.flatMap { device -> [Wanted] in
      guard case .ready(let storages) = device.state else { return [] }
      let model = device.info.model
      let base =
        models[model, default: 0] > 1 ? "\(model) (\(device.id.serial.suffix(4)))" : model
      return storages.enumerated().map { index, storage in
        let identity = aliases.identity(of: storage.id)
        let spec = DomainSpec(
          identifier: identifier(for: identity),
          displayName: index == 0 ? base : base + " – SD card")
        var formers = [storage.formerKey].compactMap { $0 } + aliases.mtpKeys(of: identity)
        if storage.id.key == StorageKey.internal {
          formers.append(androidInternalDescription)
        }
        let superseded = Set(formers).subtracting([identity.key]).sorted()
        return Wanted(
          spec: spec, storage: storage.id,
          formers: superseded.map { StorageID(device: device.id, key: $0) })
      }
    }
  }
}
