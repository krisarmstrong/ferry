/// What a transport found on the bus.
public struct DeviceScan: Sendable, Equatable, Codable {
  /// Devices this process can use, including those it already holds open.
  public let devices: [DeviceInfo]
  /// Devices another process holds. Their serial is unknown, so each is identified by its USB
  /// location (`usb-<bus>-<address>`), which is unique only while it stays plugged in.
  public let busy: [DeviceInfo]
  /// Devices attached but not sharing files: an Android device with file transfer off, named
  /// from USB alone like `busy`, or one this process ejected, under its own identity.
  public let notSharing: [DeviceInfo]

  public init(devices: [DeviceInfo], busy: [DeviceInfo] = [], notSharing: [DeviceInfo] = []) {
    self.devices = devices
    self.busy = busy
    self.notSharing = notSharing
  }
}
