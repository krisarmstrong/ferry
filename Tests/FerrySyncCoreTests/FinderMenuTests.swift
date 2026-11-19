import DeviceKit
import Foundation
import Testing

@testable import FerrySyncCore

func attached(
  _ serial: String, model: String, method: ConnectionMethod = .usbFileTransfer,
  state: DeviceState? = nil
) -> AttachedDevice {
  let id = DeviceID(serial: serial)
  let storage = StorageInfo(
    id: StorageID(device: id, key: StorageKey.internal), description: "Internal storage",
    capacity: 1 << 30, free: 1 << 29)
  return AttachedDevice(
    info: DeviceInfo(id: id, manufacturer: "Maker", model: model),
    state: state ?? .ready([storage]), method: method)
}

private let report = URL(filePath: "/Users/me/Documents/Report.pdf")
private let app = URL(filePath: "/Users/me/Downloads/Tester.apk")
private let otherApp = URL(filePath: "/Users/me/Downloads/Probe.APK")

/// The Finder menu: one Send per ready device, one Install per device served over ADB when the
/// selection is all apps, and a disabled line when there is nothing to do.
struct FinderMenuTests {
  @Test func noDeviceShowsADisabledLine() {
    let entries = FinderMenu.entries(devices: [], selection: [report])
    #expect(entries == [FinderMenuEntry(title: "No device connected", action: nil)])
  }

  /// A device that is not ready (file transfer off, ejected, busy) cannot take a file.
  @Test func devicesThatAreNotReadyAreLeftOut() {
    let devices = [
      attached("A", model: "Pixel 8", state: .notSharingFiles),
      attached("B", model: "LinkRunner", state: .ejected),
      attached("C", model: "Tablet", state: .ready([])),
    ]
    let entries = FinderMenu.entries(devices: devices, selection: [report])
    #expect(entries == [FinderMenuEntry(title: "No device connected", action: nil)])
  }

  @Test func oneDeviceGetsOneSend() {
    let device = attached("A", model: "LinkRunner 10G")
    let entries = FinderMenu.entries(devices: [device], selection: [report])
    #expect(entries == [FinderMenuEntry(title: "Send to LinkRunner 10G", action: .send(device.id))])
  }

  /// Install is offered only on devices served over ADB, and only when every selected item is an
  /// app, whatever the case of its extension.
  @Test func twoDevicesAndAppsOfferInstallOverADBOnly() {
    let usb = attached("A", model: "LinkRunner", method: .usbADB)
    let mtp = attached("B", model: "Pixel 8", method: .usbFileTransfer)
    let wifi = attached("C", model: "Tablet", method: .wifiADB)
    let entries = FinderMenu.entries(devices: [usb, mtp, wifi], selection: [app, otherApp])
    #expect(
      entries == [
        FinderMenuEntry(title: "Send to LinkRunner", action: .send(usb.id)),
        FinderMenuEntry(title: "Send to Pixel 8", action: .send(mtp.id)),
        FinderMenuEntry(title: "Send to Tablet", action: .send(wifi.id)),
        FinderMenuEntry(title: "Install on LinkRunner", action: .install(usb.id)),
        FinderMenuEntry(title: "Install on Tablet", action: .install(wifi.id)),
      ])
  }

  @Test func aMixedSelectionOffersNoInstall() {
    let device = attached("A", model: "LinkRunner", method: .usbADB)
    let entries = FinderMenu.entries(devices: [device], selection: [app, report])
    #expect(entries == [FinderMenuEntry(title: "Send to LinkRunner", action: .send(device.id))])
  }

  /// The toolbar menu can open with nothing selected.
  @Test func anEmptySelectionAsksForFiles() {
    let device = attached("A", model: "LinkRunner", method: .usbADB)
    let entries = FinderMenu.entries(devices: [device], selection: [])
    #expect(entries == [FinderMenuEntry(title: "Select files to send", action: nil)])
  }

  /// A device names itself: control and bidi characters show as escapes, never as text that
  /// reorders the menu.
  @Test func deviceNamesAreEscaped() {
    let device = attached("A", model: "Phone\u{202E}fdp.exe")
    let entries = FinderMenu.entries(devices: [device], selection: [report])
    #expect(entries.first?.title == "Send to Phone\\u{202E}fdp.exe")
  }

  /// Two devices with one model stay apart by their actions.
  @Test func eachEntryActsOnItsOwnDevice() {
    let first = attached("A", model: "Pixel 8")
    let second = attached("B", model: "Pixel 8")
    let actions = FinderMenu.entries(devices: [first, second], selection: [report]).map(\.action)
    #expect(actions == [.send(first.id), .send(second.id)])
  }
}
