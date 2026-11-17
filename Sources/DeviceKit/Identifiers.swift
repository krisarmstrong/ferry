public struct DeviceID: Hashable, Sendable, Codable {
  public let serial: String

  public init(serial: String) {
    self.serial = serial
  }
}

public struct StorageID: Hashable, Sendable, Codable {
  public let device: DeviceID
  /// `"<StorageDescription>|<VolumeIdentifier>"`, stable across reconnects.
  public let key: String

  public init(device: DeviceID, key: String) {
    self.device = device
    self.key = key
  }
}
