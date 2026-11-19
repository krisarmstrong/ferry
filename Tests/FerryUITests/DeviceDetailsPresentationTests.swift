import DeviceKit
import Foundation
import Testing

@testable import FerryUI

/// The details an expanded device shows inline: a line per port or interface with its IPv4
/// address, then the Android version and battery.
struct DeviceDetailsPresentationTests {
  private func info(
    model: String = "EtherScope-nXG", version: String = "8.1.0",
    battery: AndroidDeviceInfo.Battery? = .init(level: 100, state: .full),
    _ addresses: [AndroidDeviceInfo.Address]
  ) -> AndroidDeviceInfo {
    AndroidDeviceInfo(
      model: model, androidVersion: version, build: "OPM1", serial: "S", battery: battery,
      addresses: addresses, storage: nil)
  }

  private func shown(_ lines: [DevicePresentation.DetailLine]) -> [String] {
    lines.map { "\($0.label)=\($0.value)" }
  }

  /// A known model lists every port in the unit's order, a port with no IPv4 address as not
  /// connected; IPv6 addresses and interfaces that are not ports are left out.
  @Test(arguments: [
    (
      [
        AndroidDeviceInfo.Address(interface: "dummy0", address: "192.0.2.13"),
        .init(interface: "wlan0", address: "192.0.2.159"),
        .init(interface: "wlan0", address: "2001:db8::159"),
        .init(interface: "eno0", address: "192.0.2.156"),
        .init(interface: "eno0", address: "2001:db8::156"),
        .init(interface: "wax0", address: "192.0.2.160"),
      ],
      [
        "Wi-Fi Management=192.0.2.159", "Wired Management=Not connected",
        "Wired Test=192.0.2.156", "Wi-Fi Test=192.0.2.160",
      ]
    ),
    (
      [.init(interface: "eth0", address: "2001:db8::10")],
      [
        "Wi-Fi Management=Not connected", "Wired Management=Not connected",
        "Wired Test=Not connected", "Wi-Fi Test=Not connected",
      ]
    ),
  ])
  func aKnownModelShowsEveryPort(addresses: [AndroidDeviceInfo.Address], expected: [String]) {
    let lines = DevicePresentation.detailLines(info(addresses))
    #expect(shown(lines) == expected)
    #expect(lines.map(\.id) == ["wlan0", "eth0", "eno0", "wax0"])
    #expect(lines.filter { $0.address == nil }.allSatisfy { $0.value == "Not connected" })
  }

  /// Any other model has a line per interface with an IPv4 address, named for its kind of link,
  /// in the order the device listed them; the first IPv4 address of each is shown.
  @Test func anyOtherModelShowsItsIPv4Interfaces() {
    let lines = DevicePresentation.detailLines(
      info(
        model: "LinkRunner G2",
        [
          .init(interface: "wlan0", address: "2001:db8::1"),
          .init(interface: "wlan0", address: "192.0.2.10"),
          .init(interface: "wlan0", address: "192.0.2.11"),
          .init(interface: "eth0", address: "192.0.2.20"),
          .init(interface: "rmnet_data0", address: "2001:db8::30"),
          .init(interface: "rndis0", address: "192.0.2.40"),
          .init(interface: "tun0", address: "192.0.2.50"),
        ]))
    #expect(
      shown(lines) == [
        "Wi-Fi=192.0.2.10", "Ethernet=192.0.2.20", "USB=192.0.2.40", "tun0=192.0.2.50",
      ])
    #expect(lines.map(\.id) == ["wlan0", "eth0", "rndis0", "tun0"])
  }

  /// Two links of one kind would read alike: each then names its interface, so the lines and
  /// their copy actions can be told apart.
  @Test func twoLinksOfOneKindNameTheirInterfaces() {
    let lines = DevicePresentation.detailLines(
      info(
        model: "LinkRunner G2",
        [
          .init(interface: "wlan0", address: "192.0.2.10"),
          .init(interface: "eth0", address: "192.0.2.20"),
          .init(interface: "wlan1", address: "192.0.2.11"),
        ]))
    #expect(lines.map(\.label) == ["Wi-Fi (wlan0)", "Ethernet", "Wi-Fi (wlan1)"])
    let actions = lines.map { String(localized: DevicePresentation.copyAddressResource($0)) }
    #expect(Set(actions).count == actions.count)
  }

  /// Only a dotted-decimal IPv4 address is shown and copied, never whatever else the device sent.
  @Test(arguments: [
    "192.0.2", "192.0.2.256", "::ffff:192.0.2.1", "192.0.2.1\u{202E}", "", "192.0.2.1\0",
    "192.0.2.1\0tail", "١٩٢.0.2.1", "192.0.2.1 ",
  ])
  func onlyAnIPv4AddressIsShown(address: String) {
    let lines = DevicePresentation.detailLines(
      info(model: "Box", [.init(interface: "wlan0", address: address)]))
    #expect(lines.isEmpty)
  }

  /// An interface name the device made up is shown as text.
  @Test func anInterfaceNameIsEscaped() {
    let lines = DevicePresentation.detailLines(
      info(model: "Box", [.init(interface: "x\u{1B}0", address: "192.0.2.1")]))
    #expect(lines.map(\.label) == ["x\\u{1B}0"])
  }

  @Test(arguments: [
    (
      "8.1.0", AndroidDeviceInfo.Battery(level: 87, state: .charging), "Android 8.1.0 · Battery 87%"
    ),
    ("8.1.0", nil, "Android 8.1.0"),
    ("", .init(level: 5, state: .unknown), "Battery 5%"),
  ])
  func theSystemLineLeavesOutWhatIsUnknown(
    version: String, battery: AndroidDeviceInfo.Battery?, expected: String
  ) {
    #expect(DevicePresentation.systemLine(info(version: version, battery: battery, [])) == expected)
  }

  @Test func noVersionAndNoBatteryHaveNoLine() {
    #expect(DevicePresentation.systemLine(info(version: "", battery: nil, [])) == nil)
  }

  @Test func theAndroidVersionIsEscaped() {
    let line = DevicePresentation.systemLine(info(version: "8\u{202E}", battery: nil, []))
    #expect(line == "Android 8\\u{202E}")
  }

  /// Copy Device Details puts the Device Info text on the pasteboard: a `Label: value` line per
  /// row, every address of every port included.
  @Test func theFullTextHasEveryAddress() {
    let text = DevicePresentation.detailsText(
      info([
        .init(interface: "dummy0", address: "192.0.2.13"),
        .init(interface: "wlan0", address: "192.0.2.159"),
        .init(interface: "wlan0", address: "2001:db8::159"),
      ]))
    #expect(
      text == """
        Model: EtherScope-nXG
        Android version: 8.1.0
        Build: OPM1
        Serial number: S
        Battery: 100%, full
        Wi-Fi Management: 192.0.2.159, 2001:db8::159
        Wired Management: Not connected
        Wired Test: Not connected
        Wi-Fi Test: Not connected
        IP addresses: 192.0.2.13 (dummy0)
        """)
  }

  /// VoiceOver reads a line as "<label>, <value>", and its copy action names the port.
  @Test func aLineReadsAsItsLabelAndValue() {
    let line = DevicePresentation.DetailLine(
      id: "wlan0", label: "Wi-Fi Management", address: "192.0.2.159")
    #expect(
      DevicePresentation.detailLabel(line, copied: false) == "Wi-Fi Management, 192.0.2.159")
    #expect(DevicePresentation.detailLabel(line, copied: true) == "Wi-Fi Management, Copied")
    #expect(
      String(localized: DevicePresentation.copyAddressResource(line))
        == "Copy Wi-Fi Management address")
  }
}
