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
    addresses: ["192.0.2.31", "198.51.100.169"],
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
    #expect(rows[5].value == "192.0.2.31, 198.51.100.169")
    #expect(rows[6].value.contains("used") && rows[6].value.contains("free"))
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
      addresses: [], storage: nil)
    let rows = DevicePresentation.infoRows(hostile)
    #expect(rows[0].value == "A\\u{1B}[2Jb")
    #expect(rows[1].value == "8\\u{202E}")
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
    #expect(copied.contains("IP addresses: 192.0.2.31, 198.51.100.169"))
  }

  @Test func copyBeforeTheInfoIsHereDoesNothing() {
    let session = DeviceInfoSession(
      device: id, client: FakeClient(log: log), services: FakeServices(log: log))
    session.copy()
    #expect(!log.all.contains { $0.hasPrefix("copy ") })
  }
}
