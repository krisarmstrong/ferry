/// How Ferry reaches a device. One device can be reachable several ways at once; the hub serves
/// it over the preferred one (see `isPreferred(over:)`).
public enum ConnectionMethod: String, Sendable, Codable, CaseIterable {
  /// ADB over a USB cable: the adb server's USB route.
  case usbADB
  /// ADB over the network: the adb server's `host:port` route.
  case wifiADB
  /// MTP over USB, which Android calls File transfer. The fallback whenever ADB is off,
  /// unauthorised or not installed.
  case usbFileTransfer

  /// Any USB route beats a network one, and on USB, ADB beats MTP: ADB lists and copies faster
  /// and offers the tools. A network route serves a device only while no USB route presents its
  /// serial, so a device on the network that claims a cabled unit's serial cannot take it over.
  public func isPreferred(over other: ConnectionMethod) -> Bool {
    rank < other.rank
  }

  private var rank: Int {
    switch self {
    case .usbADB: 0
    case .usbFileTransfer: 1
    case .wifiADB: 2
    }
  }
}
