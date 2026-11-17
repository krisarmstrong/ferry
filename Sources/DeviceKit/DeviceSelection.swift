/// Picks the device and storage a command or app acts on from what the transport reported.
public enum DeviceSelection {
  /// The usable devices, which must not be empty: listing no phones is an error, not an empty
  /// answer. When the only phones are held by another app, the error says so.
  public static func requireAny(_ scan: DeviceScan) throws(TransportError) -> [DeviceInfo] {
    guard !scan.devices.isEmpty else { throw scan.busy.isEmpty ? .noDeviceConnected : .deviceBusy }
    return scan.devices
  }

  /// The device with `serial`, or the first one when `serial` is nil.
  public static func pickDevice(serial: String?, from scan: DeviceScan)
    throws(TransportError) -> DeviceInfo
  {
    let devices = try requireAny(scan)
    guard let serial else { return devices[0] }
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
