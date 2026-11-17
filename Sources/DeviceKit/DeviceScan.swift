/// What a transport found on the bus.
public struct DeviceScan: Sendable, Equatable, Codable {
  /// Devices this process can use, including those it already holds open.
  public let devices: [DeviceInfo]
  /// Devices another process holds. Their serial is unknown, so each is identified by its USB
  /// location (`usb-<bus>-<address>`), which is unique only while it stays plugged in.
  public let busy: [DeviceInfo]

  public init(devices: [DeviceInfo], busy: [DeviceInfo] = []) {
    self.devices = devices
    self.busy = busy
  }
}
