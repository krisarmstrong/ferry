import Foundation

/// The network ports of models whose interfaces Ferry knows, keyed on `ro.product.model`, in
/// the order the unit labels them. Device Info lists every one, connected or not.
enum KnownPorts {
  struct Port {
    /// As the device names it (`wlan0`).
    let interface: String
    let name: LocalizedStringResource
  }

  static func ports(ofModel model: String) -> [Port]? {
    switch model {
    case "EtherScope_nXG":
      [
        Port(
          interface: "wlan0", name: LocalizedStringResource("Wi-Fi Management", bundle: .module)),
        Port(
          interface: "eth0", name: LocalizedStringResource("Wired Management", bundle: .module)),
        Port(interface: "eno0", name: LocalizedStringResource("Wired Test", bundle: .module)),
        Port(interface: "wax0", name: LocalizedStringResource("Wi-Fi Test", bundle: .module)),
      ]
    default:
      nil
    }
  }
}
