import Foundation

/// The network ports of models whose interfaces Ferry knows, keyed on `ro.product.model` as
/// `getprop` prints it (adb's device list rewrites `-` as `_`), in the order the unit labels
/// them. A device's details list every one, connected or not.
enum KnownPorts {
  struct Port {
    /// As the device names it (`wlan0`).
    let interface: String
    let name: LocalizedStringResource
  }

  /// The CyberScope is built on the EtherScope nXG and labels the same ports; its model name is
  /// matched by its start, which no unit's report has confirmed yet.
  static func ports(ofModel model: String) -> [Port]? {
    guard model == "EtherScope-nXG" || model.lowercased().hasPrefix("cyberscope") else {
      return nil
    }
    return [
      Port(
        interface: "wlan0", name: LocalizedStringResource("Wi-Fi Management", bundle: .module)),
      Port(
        interface: "eth0", name: LocalizedStringResource("Wired Management", bundle: .module)),
      Port(interface: "eno0", name: LocalizedStringResource("Wired Test", bundle: .module)),
      Port(interface: "wax0", name: LocalizedStringResource("Wi-Fi Test", bundle: .module)),
    ]
  }
}
