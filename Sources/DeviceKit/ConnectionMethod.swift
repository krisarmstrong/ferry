/// How Ferry reaches a device. One device can be reachable several ways at once; the hub serves
/// it over the most preferred one (see `isPreferred(over:)`).
public enum ConnectionMethod: String, Sendable, Codable, CaseIterable {
  /// ADB over a USB cable: the adb server's USB route.
  case usbADB
  /// ADB over the network: the adb server's `host:port` route.
  case wifiADB
  /// MTP over USB, which Android calls File transfer. The fallback whenever ADB is off,
  /// unauthorised or not installed.
  case usbFileTransfer

  /// ADB over USB beats ADB over the network, which beats MTP: ADB lists and copies faster than
  /// MTP and offers the tools, and USB is faster and steadier than the network.
  public func isPreferred(over other: ConnectionMethod) -> Bool {
    rank < other.rank
  }

  private var rank: Int {
    switch self {
    case .usbADB: 0
    case .wifiADB: 1
    case .usbFileTransfer: 2
    }
  }
}
