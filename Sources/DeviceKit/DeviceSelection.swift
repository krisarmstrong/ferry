/// Picks the device and storage a command or app acts on from what the transport reported.
public enum DeviceSelection {
  /// `devices`, which must not be empty: listing no phones is an error, not an empty answer.
  public static func requireAny(_ devices: [DeviceInfo]) throws(TransportError) -> [DeviceInfo] {
    guard !devices.isEmpty else { throw .noDeviceConnected }
    return devices
  }

  /// The device with `serial`, or the first one when `serial` is nil.
  public static func pickDevice(serial: String?, from devices: [DeviceInfo])
    throws(TransportError) -> DeviceInfo
  {
    guard let serial else {
      guard let first = devices.first else { throw .noDeviceConnected }
      return first
    }
    guard let match = devices.first(where: { $0.id.serial == serial }) else {
      throw .deviceNotFound(DeviceID(serial: serial))
    }
    return match
  }

  /// The storage whose description is `description`, or the first one when it is nil.
  public static func pickStorage(description: String?, from storages: [StorageInfo])
    throws(TransportError) -> StorageInfo
  {
    guard let description else {
      guard let first = storages.first else { throw .noStorage }
      return first
    }
    guard let match = storages.first(where: { $0.description == description }) else {
      throw .storageNotFound(description)
    }
    return match
  }
}
