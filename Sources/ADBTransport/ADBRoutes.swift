import DeviceKit

/// The adb serials a device answers on: its USB serial and any `host:port` it is connected at.
public struct ADBRoutes: Sendable, Equatable {
  public let usb: String?
  public let wireless: [String]

  public init(usb: String?, wireless: [String]) {
    self.usb = usb
    self.wireless = wireless
  }

  /// The route a session uses: USB while the cable is in.
  public var preferred: String? { usb ?? wireless.first }

  var serials: Set<String> { Set(wireless + [usb].compactMap { $0 }) }
}

/// Where the tools reach a device: its adb serial and, where adb reports one, the server's
/// connection to the unit (`transport_id`) the serial named when the route was taken. Every
/// tool connection selects by that connection, so after adb reconnects the address to another
/// unit it fails as gone rather than reaching that unit, however long ago the route was taken.
public struct ADBRoute: Sendable, Hashable {
  public let serial: String
  public let transportID: String?

  public init(serial: String, transportID: String? = nil) {
    self.serial = serial
    self.transportID = transportID
  }
}

/// Told when a session opens: the device, the route it opened on, and the tools over the same
/// server. It must return at once; work it starts runs on its own task.
public typealias ADBOpenHandler =
  @Sendable (_ id: DeviceID, _ route: ADBRoute, _ tools: ADBDeviceTools)
  -> Void

/// Whether a network route (`host:port`, or an mDNS name) may serve the device it answers as.
/// The agent decides: an address it has not vouched for never serves a device Ferry knows.
public typealias ADBNetworkPolicy = @Sendable (_ adbSerial: String, _ id: DeviceID) -> Bool
