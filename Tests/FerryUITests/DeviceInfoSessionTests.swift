import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// The Device Info sheet: what it asks, what it shows, and the text Copy puts on the pasteboard.
@MainActor
struct DeviceInfoSessionTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")

  static let info = AndroidDeviceInfo(
    model: "LinkRunner G2", androidVersion: "8.1.0", build: "OPM1.171019.026",
    serial: "0123456789abcdef", battery: .init(level: 87, state: .charging),
    addresses: [
      .init(interface: "wlan0", address: "198.51.100.169"),
      .init(interface: "eth0", address: "192.0.2.31"),
      .init(interface: "rmnet_data0", address: "100.64.1.2"),
      .init(interface: "rndis0", address: "192.168.42.129"),
      .init(interface: "tun0", address: "10.8.0.2"),
    ],
    storage: .init(used: 5_000_000_000, free: 17_000_000_000))

  @Test func theInfoIsLoaded() async {
    let client = FakeClient(log: log)
    client.infoReply.withLock { $0 = .deviceInfo(Self.info) }
    let session = DeviceInfoSession(device: id, client: client, services: FakeServices(log: log))
    await session.load()
    #expect(session.state == .loaded(Self.info))
    #expect(log.all.contains("deviceInfo \(id.serial)"))
  }

  @Test func aFailureIsShown() async {
    let client = FakeClient(log: log)
    client.infoReply.withLock { $0 = .toolFailed(.notOverADB) }
    let session = DeviceInfoSession(device: id, client: client, services: FakeServices(log: log))
    await session.load()
    #expect(session.state == .failed(DevicePresentation.message(for: .notOverADB)))
  }

  @Test func aLostDeviceIsShown() async {
    let session = DeviceInfoSession(
      device: id, client: UnreachableClient(), services: FakeServices(log: log))
    await session.load()
    #expect(session.state == .failed(DevicePresentation.message(for: .deviceDisconnected)))
  }

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
        == "198.51.100.169 (Wi-Fi), 192.0.2.31 (Ethernet), 100.64.1.2 (Mobile data), "
        + "192.168.42.129 (USB), 10.8.0.2 (tun0)")
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
        .init(interface: "tun0", address: "10.8.0.2"),
      ],
      [
        "Wi-Fi Management": "192.0.2.159, 2001:db8::159", "Wired Management": "192.0.2.10",
        "Wired Test": "Not connected", "Wi-Fi Test": "Not connected",
      ],
      "10.8.0.2 (tun0)"
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

  @Test func copyPutsTheRowsOnThePasteboardOnePerLine() async {
    let client = FakeClient(log: log)
    client.infoReply.withLock { $0 = .deviceInfo(Self.info) }
    let session = DeviceInfoSession(device: id, client: client, services: FakeServices(log: log))
    await session.load()
    session.copy()
    let copied = log.all.first { $0.hasPrefix("copy ") } ?? ""
    #expect(copied.contains("Model: LinkRunner G2"))
    #expect(copied.contains("Battery: 87%, charging"))
    #expect(copied.contains("IP addresses: 198.51.100.169 (Wi-Fi), 192.0.2.31 (Ethernet)"))
  }

  @Test func copyBeforeTheInfoIsHereDoesNothing() {
    let session = DeviceInfoSession(
      device: id, client: FakeClient(log: log), services: FakeServices(log: log))
    session.copy()
    #expect(!log.all.contains { $0.hasPrefix("copy ") })
  }
}
