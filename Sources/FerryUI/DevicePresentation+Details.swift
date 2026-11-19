import DeviceKit
import FerryText
import Foundation

/// What a device says about itself, as an expanded device shows it inline (a line per port or
/// interface with its IPv4 address, then its Android version and battery) and as Copy All
/// Details copies it. Every value is the device's, so it is escaped.
extension DevicePresentation {
  /// One port or interface: its name on the left, its IPv4 address (or "Not connected") on the
  /// right.
  struct DetailLine: Equatable, Identifiable {
    /// The interface, as the device names it: two of one kind of link share a label.
    let id: String
    let label: String
    /// The address shown and copied; `nil` for a known port with no IPv4 address.
    let address: String?

    var value: String { address ?? notConnected }
  }

  /// For a model whose ports Ferry knows (`KnownPorts`), every port in the unit's order;
  /// otherwise each interface with an IPv4 address, named for its kind of link, in the order the
  /// device listed them. Each shows its first IPv4 address; IPv6 addresses are left out.
  static func detailLines(_ info: AndroidDeviceInfo) -> [DetailLine] {
    let ipv4 = info.addresses.filter { isIPv4($0.address) }
    func firstAddress(on interface: String) -> String? {
      ipv4.first { $0.interface == interface }.map(\.address)
    }
    if let ports = KnownPorts.ports(ofModel: info.model) {
      return ports.map { port in
        DetailLine(
          id: port.interface, label: String(localized: port.name),
          address: firstAddress(on: port.interface))
      }
    }
    var lines: [DetailLine] = []
    for address in ipv4 where !lines.contains(where: { $0.id == address.interface }) {
      lines.append(
        DetailLine(id: address.interface, label: linkName(address.kind), address: address.address))
    }
    return lines
  }

  /// "Android <version> · Battery <n>%", leaving out what the device did not say.
  static func systemLine(_ info: AndroidDeviceInfo) -> String? {
    systemLineResource(info).map { String(localized: $0) }
  }

  static func systemLineResource(_ info: AndroidDeviceInfo) -> LocalizedStringResource? {
    let version = DisplayText.escaped(info.androidVersion)
    switch (version.isEmpty, info.battery?.level) {
    case (false, let level?):
      return LocalizedStringResource("Android \(version) · Battery \(level)%", bundle: .module)
    case (false, nil):
      return LocalizedStringResource("Android \(version)", bundle: .module)
    case (true, let level?):
      return LocalizedStringResource("Battery \(level)%", bundle: .module)
    case (true, nil):
      return nil
    }
  }

  /// What VoiceOver reads for a line: its label, then its value, or "Copied" just after a copy.
  static func detailLabel(_ line: DetailLine, copied: Bool) -> String {
    let (label, value) = (line.label, copied ? String(localized: copiedResource) : line.value)
    return String(localized: LocalizedStringResource("\(label), \(value)", bundle: .module))
  }

  static func copyAddressResource(_ line: DetailLine) -> LocalizedStringResource {
    let label = line.label
    return LocalizedStringResource("Copy \(label) address", bundle: .module)
  }

  static let copiedResource = LocalizedStringResource("Copied", bundle: .module)
  static let loadingDetailsResource = LocalizedStringResource("Loading details…", bundle: .module)

  private static var notConnected: String {
    String(localized: LocalizedStringResource("Not connected", bundle: .module))
  }

  private static func isIPv4(_ text: String) -> Bool {
    var address = in_addr()
    return inet_pton(AF_INET, text, &address) == 1
  }

  /// What Copy All Details copies: a `Label: value` line per row of `infoRows`.
  static func detailsText(_ info: AndroidDeviceInfo) -> String {
    infoRows(info).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
  }

  struct InfoRow: Equatable {
    let label: String
    let value: String
  }

  /// Everything the device said about itself, a row each; a part it could not say has no row. A
  /// model whose ports Ferry knows (`KnownPorts`) has a row per port with all its addresses, and
  /// "IP addresses" only for any other interface.
  static func infoRows(_ info: AndroidDeviceInfo) -> [InfoRow] {
    var rows: [InfoRow] = []
    func add(_ label: LocalizedStringResource, _ value: String) {
      guard !value.isEmpty else { return }
      rows.append(InfoRow(label: String(localized: label), value: value))
    }
    add(LocalizedStringResource("Model", bundle: .module), DisplayText.escaped(info.model))
    add(
      LocalizedStringResource("Android version", bundle: .module),
      DisplayText.escaped(info.androidVersion))
    add(LocalizedStringResource("Build", bundle: .module), DisplayText.escaped(info.build))
    add(LocalizedStringResource("Serial number", bundle: .module), DisplayText.escaped(info.serial))
    if let battery = info.battery {
      add(LocalizedStringResource("Battery", bundle: .module), batteryLine(battery))
    }
    var others = info.addresses
    if let ports = KnownPorts.ports(ofModel: info.model) {
      for port in ports {
        let found = info.addresses.filter { $0.interface == port.interface }
        add(
          port.name,
          found.isEmpty
            ? notConnected : found.map { DisplayText.escaped($0.address) }.joined(separator: ", "))
      }
      others.removeAll { address in ports.contains { $0.interface == address.interface } }
    }
    add(
      LocalizedStringResource("IP addresses", bundle: .module),
      others.map(addressLine).joined(separator: ", "))
    if let storage = info.storage {
      add(LocalizedStringResource("Storage", bundle: .module), storageLine(storage))
    }
    return rows
  }

  /// The kind of link an interface is, or the interface's own name for any other.
  private static func linkName(_ kind: InterfaceKind) -> String {
    switch kind {
    case .wifi: String(localized: LocalizedStringResource("Wi-Fi", bundle: .module))
    case .ethernet: String(localized: LocalizedStringResource("Ethernet", bundle: .module))
    case .mobileData: String(localized: LocalizedStringResource("Mobile data", bundle: .module))
    case .usb: String(localized: LocalizedStringResource("USB", bundle: .module))
    case .other(let name): DisplayText.escaped(name)
    }
  }

  /// The address, then the kind of link it is on.
  private static func addressLine(_ address: AndroidDeviceInfo.Address) -> String {
    let link = linkName(address.kind)
    let value = DisplayText.escaped(address.address)
    return String(localized: LocalizedStringResource("\(value) (\(link))", bundle: .module))
  }

  private static func batteryLine(_ battery: AndroidDeviceInfo.Battery) -> String {
    let level = battery.level
    return switch battery.state {
    case .charging:
      String(localized: LocalizedStringResource("\(level)%, charging", bundle: .module))
    case .discharging:
      String(localized: LocalizedStringResource("\(level)%, discharging", bundle: .module))
    case .notCharging:
      String(localized: LocalizedStringResource("\(level)%, not charging", bundle: .module))
    case .full:
      String(localized: LocalizedStringResource("\(level)%, full", bundle: .module))
    case .unknown:
      String(localized: LocalizedStringResource("\(level)%", bundle: .module))
    }
  }

  private static func storageLine(_ storage: AndroidDeviceInfo.Storage) -> String {
    let used = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: storage.used), countStyle: .file)
    let free = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: storage.free), countStyle: .file)
    return String(localized: LocalizedStringResource("\(used) used, \(free) free", bundle: .module))
  }
}
