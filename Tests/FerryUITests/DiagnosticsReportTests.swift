import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Copy Diagnostics puts a plain-text report on the pasteboard, for the user to paste into a
/// support message. It says what support needs (versions, adb, the devices and what failed)
/// and nothing private: no serial, no network address, no file or folder in the home folder,
/// as `LogPrivacyTests` keeps them out of the log.
@MainActor
struct DiagnosticsReportTests {
  let log = CallLog()

  private static let serials = ["R58N12345XY", "0123456789abcdef"]

  private static func storage(_ device: DeviceID) -> StorageInfo {
    StorageInfo(
      id: StorageID(device: device, key: "internal"), description: "Kris's SD card",
      capacity: 64_000_000_000, free: 1_000_000_000)
  }

  /// A phone over USB debugging, one over Wi-Fi whose id is its address, a tester over file
  /// transfer that failed on a path, and an error whose detail names a home folder.
  private func reportedModel() async throws -> (AppModel, FakeServices) {
    let usb = DeviceID(serial: Self.serials[0])
    let wifi = DeviceID(serial: "192.0.2.42:5555")
    let tester = DeviceID(serial: Self.serials[1])
    let client = FakeClient(log: log)
    client.setStatus(
      [
        AttachedDevice(
          info: DeviceInfo(id: usb, manufacturer: "Samsung", model: "SM-G991B"),
          state: .ready([Self.storage(usb)]), method: .usbADB),
        AttachedDevice(
          info: DeviceInfo(id: wifi, manufacturer: "Google", model: "Pixel 8"),
          state: .ready([Self.storage(wifi)]), method: .wifiADB),
        AttachedDevice(
          info: DeviceInfo(id: tester, manufacturer: "NetAlly", model: "EtherScope-nXG"),
          state: .failed(.notFound(try RemotePath("/Download/\(Self.serials[1]).pcap"))),
          method: .usbFileTransfer),
      ], adb: .available,
      awaitingAuthorization: ["[2001:db8::7]:5555"],
      connectedAddresses: [wifi: try #require(WirelessEndpoint(parsing: "192.0.2.42"))])
    let services = FakeServices(log: log)
    services.fetchedVersion = "36.0.0"
    let model = AppModel(client: client, services: services)
    await model.refresh()
    model.actionError = DevicePresentation.notice(
      for: .io("open /Users/someone/Documents/capture.pcap from 192.0.2.42"))
    model.actionError = DevicePresentation.notice(for: .insufficientSpace(needed: 9, free: 1))
    return (model, services)
  }

  @Test func theReportGoesToThePasteboardAndSaysWhatSupportNeeds() async throws {
    let (model, _) = try await reportedModel()
    model.copyDiagnostics()
    let copied = try #require(log.all.last { $0.hasPrefix("copy ") })
    let report = String(copied.dropFirst("copy ".count))
    #expect(report == model.diagnosticsReport())
    for expected in [
      "Ferry diagnostics", "macOS: ", "Helper: running, build agent-1",
      "adb: installed, server running; Ferry's adb 36.0.0",
      "SM-G991B · usbADB · ready", "Pixel 8 · wifiADB · ready",
      "EtherScope-nXG · usbFileTransfer · failed (notFound)",
      "The device is out of space. Free some space on it, then try again.",
      "Ferry couldn't finish this. Try again; if it keeps failing, reconnect the device or "
        + "reopen Ferry.",
    ] {
      #expect(report.contains(expected), "\(expected)")
    }
  }

  @Test func theReportHoldsNoSerialAddressOrHomePath() async throws {
    let (model, _) = try await reportedModel()
    let report = model.diagnosticsReport()
    for serial in Self.serials {
      #expect(!report.contains(serial), "\(serial)")
    }
    #expect(report.firstMatch(of: /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/) == nil)
    #expect(report.firstMatch(of: /[0-9a-fA-F]{1,4}::?[0-9a-fA-F]{0,4}:/) == nil)
    #expect(!report.contains("/Users/"))
    #expect(!report.contains("someone"))
    #expect(!report.contains(".pcap"))
    #expect(!report.contains("Kris"))
  }

  /// Before the helper has answered, the report says so rather than guessing.
  @Test func anUnansweredHelperIsSaidPlainly() {
    let services = FakeServices(log: log)
    let model = AppModel(client: FakeClient(log: log), services: services)
    let report = model.diagnosticsReport()
    #expect(report.contains("Helper: checking"))
    #expect(report.contains("adb: not checked yet"))
    #expect(report.contains("Devices: none"))
    #expect(report.contains("Recent errors: none"))
  }

  /// Only the last few errors are kept, oldest first; one shown again without a change
  /// between is the same error, kept once.
  @Test func onlyTheLastErrorsAreKept() {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    model.actionError = DevicePresentation.notice(for: .deviceBusy)
    model.actionError = DevicePresentation.notice(for: .deviceBusy)
    #expect(model.recentErrors.count == 1)
    for index in 0..<AppModel.recentErrorLimit {
      model.actionError = DevicePresentation.notice(
        for: index.isMultiple(of: 2) ? .noStorage : .deviceBusy)
    }
    model.actionError = DevicePresentation.notice(for: .cancelled)
    #expect(model.recentErrors.count == AppModel.recentErrorLimit)
    #expect(model.recentErrors.last == "Cancelled.")
  }
}
