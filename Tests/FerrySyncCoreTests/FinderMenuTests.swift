import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerrySyncCore

func attached(
  _ serial: String, model: String, method: ConnectionMethod = .usbFileTransfer,
  ready: Bool = true
) -> DeviceSummary {
  DeviceSummary(id: DeviceID(serial: serial), name: model, method: method, ready: ready)
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

  /// A device that cannot take a file now (file transfer off, ejected, no Finder location) is
  /// left out.
  @Test func devicesThatAreNotReadyAreLeftOut() {
    let devices = [
      attached("A", model: "Pixel 8", ready: false),
      attached("B", model: "LinkRunner", method: .usbADB, ready: false),
    ]
    let entries = FinderMenu.entries(devices: devices, selection: [report])
    #expect(entries == [FinderMenuEntry(title: "No device connected", action: nil)])
  }

  @Test func oneDeviceGetsOneSend() {
    let device = attached("A", model: "LinkRunner 10G")
    let entries = FinderMenu.entries(devices: [device], selection: [report])
    #expect(entries == [FinderMenuEntry(title: "Send to LinkRunner 10G", action: .send(device.id))])
  }

  /// Two units of one model whose serials end alike are named as the Ferry menu and their
  /// Finder locations name them; a device that is not ready still counts, as the menu lists it.
  @Test func sameNamedDevicesAreToldApart() {
    let first = attached("0123456789abcdef", model: "LinkRunner-100G")
    let second = attached("0b1771d6dd935e72", model: "LinkRunner-100G")
    let away = attached("0c1771d6dd935e72", model: "LinkRunner-100G", ready: false)
    let entries = FinderMenu.entries(devices: [first, second, away], selection: [report])
    #expect(
      entries.map(\.title) == [
        "Send to LinkRunner-100G (a1771d6dd935e72)", "Send to LinkRunner-100G (b1771d6dd935e72)",
      ])
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

  /// A device that reports neither model nor manufacturer is named as the Ferry menu names it.
  @Test func aNamelessDeviceIsAnUnknownDevice() {
    let entries = FinderMenu.entries(devices: [attached("A", model: "")], selection: [report])
    #expect(entries.first?.title == "Send to Unknown device")
  }

  /// Two devices with one model stay apart by their actions.
  @Test func eachEntryActsOnItsOwnDevice() {
    let first = attached("A", model: "Pixel 8")
    let second = attached("B", model: "Pixel 8")
    let actions = FinderMenu.entries(devices: [first, second], selection: [report]).map(\.action)
    #expect(actions == [.send(first.id), .send(second.id)])
  }
}

/// Each menu item stays bound to the device and the selection of the menu Finder showed, however
/// many menus are built before the click.
struct FinderMenuBookTests {
  private let first = URL(filePath: "/Users/me/a.txt")
  private let second = URL(filePath: "/Users/me/b.txt")

  @Test func aClickActsOnTheMenuItCameFrom() throws {
    let book = FinderMenuBook()
    let pixelA = attached("A", model: "Pixel 8")
    let pixelB = attached("B", model: "Pixel 8")
    let shown = FinderMenu.entries(devices: [pixelA, pixelB], selection: [first])
    let shownTags = book.record(shown, devices: [pixelA, pixelB], selection: [first])
    // Finder builds another menu, with the devices the other way round, before the click. The
    // notice names each unit as the menu did, told apart by its serial.
    let later = FinderMenu.entries(devices: [pixelB, pixelA], selection: [second])
    let laterTags = book.record(later, devices: [pixelB, pixelA], selection: [second])

    let shownTag = try #require(shownTags[0])
    let laterTag = try #require(laterTags[0])
    let clicked = try #require(book.choice(for: shownTag))
    #expect(clicked == .init(action: .send(pixelA.id), device: "Pixel 8 (A)", selection: [first]))
    let other = try #require(book.choice(for: laterTag))
    #expect(other == .init(action: .send(pixelB.id), device: "Pixel 8 (B)", selection: [second]))
    #expect(Set(shownTags.compactMap { $0 }).isDisjoint(with: laterTags.compactMap { $0 }))
  }

  @Test func aDisabledLineHasNoChoice() {
    let book = FinderMenuBook()
    let entries = FinderMenu.entries(devices: [], selection: [first])
    #expect(book.record(entries, devices: [], selection: [first]) == [nil])
  }

  /// Old menus are forgotten, so the book stays small however long Finder runs.
  @Test func oldMenusAreForgotten() throws {
    let book = FinderMenuBook()
    let device = attached("A", model: "Pixel 8")
    let entries = FinderMenu.entries(devices: [device], selection: [first])
    let oldest = try #require(book.record(entries, devices: [device], selection: [first])[0])
    for _ in 0..<FinderMenuBook.menusKept {
      _ = book.record(entries, devices: [device], selection: [first])
    }
    #expect(book.choice(for: oldest) == nil)
  }
}
