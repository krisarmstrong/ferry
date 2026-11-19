import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Everything a device said about itself, a row each, as Copy Device Details copies it.
struct InfoRowsTests {
  static let info = AndroidDeviceInfo(
    model: "LinkRunner G2", androidVersion: "8.1.0", build: "OPM1.171019.026",
    serial: "0123456789abcdef", battery: .init(level: 87, state: .charging),
    addresses: [
      .init(interface: "wlan0", address: "192.0.2.169"),
      .init(interface: "eth0", address: "192.0.2.31"),
      .init(interface: "rmnet_data0", address: "192.0.2.2"),
      .init(interface: "rndis0", address: "192.0.2.129"),
      .init(interface: "tun0", address: "192.0.2.8"),
    ],
    storage: .init(used: 5_000_000_000, free: 17_000_000_000))

  @Test func theRowsNameWhatTheDeviceSaid() {
    let rows = DevicePresentation.infoRows(Self.info)
    #expect(
      rows.map(\.label) == [
        "Model", "Android version", "Build", "Serial number", "Battery", "IP addresses", "Storage",
      ])
    #expect(rows[0].value == "LinkRunner G2")
    #expect(rows[1].value == "8.1.0")
    #expect(rows[4].value == "87%, charging")
    #expect(
      rows[5].value
        == "192.0.2.169 (Wi-Fi), 192.0.2.31 (Ethernet), 192.0.2.2 (Mobile data), "
        + "192.0.2.129 (USB), 192.0.2.8 (tun0)")
    #expect(rows[6].value.contains("used") && rows[6].value.contains("free"))
  }

  /// A model whose ports Ferry knows lists each of them by the name on the unit, with "Not
  /// connected" for one that has no address; an address on any other interface keeps the
  /// generic row.
  @Test(arguments: [
    (
      [
        AndroidDeviceInfo.Address(interface: "wlan0", address: "192.0.2.159"),
        .init(interface: "eno0", address: "192.0.2.156"),
        .init(interface: "wax0", address: "192.0.2.160"),
      ],
      [
        "Wi-Fi Management": "192.0.2.159", "Wired Management": "Not connected",
        "Wired Test": "192.0.2.156", "Wi-Fi Test": "192.0.2.160",
      ],
      nil as String?
    ),
    (
      [
        .init(interface: "wlan0", address: "192.0.2.159"),
        .init(interface: "wlan0", address: "2001:db8::159"),
        .init(interface: "eth0", address: "192.0.2.10"),
        .init(interface: "tun0", address: "192.0.2.8"),
      ],
      [
        "Wi-Fi Management": "192.0.2.159, 2001:db8::159", "Wired Management": "192.0.2.10",
        "Wired Test": "Not connected", "Wi-Fi Test": "Not connected",
      ],
      "192.0.2.8 (tun0)"
    ),
    (
      [],
      [
        "Wi-Fi Management": "Not connected", "Wired Management": "Not connected",
        "Wired Test": "Not connected", "Wi-Fi Test": "Not connected",
      ], nil
    ),
  ])
  func aKnownModelListsItsPorts(
    addresses: [AndroidDeviceInfo.Address], ports: [String: String], others: String?
  ) {
    let info = AndroidDeviceInfo(
      model: "EtherScope-nXG", androidVersion: "8.1.0", build: "b", serial: "S", battery: nil,
      addresses: addresses, storage: nil)
    let rows = DevicePresentation.infoRows(info)
    let names = ["Wi-Fi Management", "Wired Management", "Wired Test", "Wi-Fi Test"]
    var expected = ["Model", "Android version", "Build", "Serial number"] + names
    if others != nil { expected.append("IP addresses") }
    #expect(rows.map(\.label) == expected)
    for name in names {
      #expect(rows.first { $0.label == name }?.value == ports[name], "\(name)")
    }
    #expect(rows.first { $0.label == "IP addresses" }?.value == others)
  }

  /// A model Ferry does not know keeps the generic labels, matched on the whole model name.
  @Test(arguments: ["LinkRunner G2", "EtherScope", "etherscope_nxg"])
  func anyOtherModelKeepsTheGenericLabels(model: String) {
    let info = AndroidDeviceInfo(
      model: model, androidVersion: "", build: "", serial: "S", battery: nil,
      addresses: [.init(interface: "wlan0", address: "192.0.2.159")], storage: nil)
    let rows = DevicePresentation.infoRows(info)
    #expect(rows.map(\.label) == ["Model", "Serial number", "IP addresses"])
    #expect(rows[2].value == "192.0.2.159 (Wi-Fi)")
  }

  /// What the device could not say is left out, not shown as an empty or zero value.
  @Test func whatIsMissingHasNoRow() {
    let bare = AndroidDeviceInfo(
      model: "Box", androidVersion: "", build: "", serial: "S", battery: nil, addresses: [],
      storage: nil)
    #expect(DevicePresentation.infoRows(bare).map(\.label) == ["Model", "Serial number"])
  }

  /// Every word is the device's: an escape sequence in it is shown as text, in the rows and in
  /// what Copy copies.
  @Test func deviceTextIsEscaped() {
    let hostile = AndroidDeviceInfo(
      model: "A\u{1B}[2Jb", androidVersion: "8\u{202E}", build: "x", serial: "S", battery: nil,
      addresses: [.init(interface: "x\u{202E}0", address: "192.0.2.1")], storage: nil)
    let rows = DevicePresentation.infoRows(hostile)
    #expect(rows[0].value == "A\\u{1B}[2Jb")
    #expect(rows[1].value == "8\\u{202E}")
    #expect(rows[4].value == "192.0.2.1 (x\\u{202E}0)")
  }
}
