import DeviceKit

/// One FileProvider domain: a single storage of one device.
public struct DomainSpec: Sendable, Hashable {
  /// `"<serial>|<StorageID.key>"`, stable across reconnects. The key contains `|` itself, so
  /// the identifier is never parsed back; the agent maps it to its storage in memory.
  public let identifier: String
  public let displayName: String

  public init(identifier: String, displayName: String) {
    self.identifier = identifier
    self.displayName = displayName
  }
}

public enum DomainNaming {
  /// A spec for each storage of each ready device, in order.
  ///
  /// A domain is named after its device's model, with the last four characters of the serial
  /// added when another listed device has the same model, and ` – SD card` added for every
  /// storage after the device's first.
  public static func specs(for devices: [AttachedDevice]) -> [DomainSpec] {
    domains(for: devices).map(\.spec)
  }

  static func domains(for devices: [AttachedDevice]) -> [(spec: DomainSpec, storage: StorageID)] {
    var models: [String: Int] = [:]
    for device in devices {
      models[device.info.model, default: 0] += 1
    }
    return devices.flatMap { device -> [(spec: DomainSpec, storage: StorageID)] in
      guard case .ready(let storages) = device.state else { return [] }
      let model = device.info.model
      let base =
        models[model, default: 0] > 1 ? "\(model) (\(device.id.serial.suffix(4)))" : model
      return storages.enumerated().map { index, storage in
        let spec = DomainSpec(
          identifier: "\(device.id.serial)|\(storage.id.key)",
          displayName: index == 0 ? base : base + " – SD card")
        return (spec, storage.id)
      }
    }
  }
}
