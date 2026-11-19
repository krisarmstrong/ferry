import AppKit
import DeviceKit
import FerryIPC
import Foundation
import SwiftUI
import Testing

@testable import FerryUI

/// Draws the menu offscreen, in light and dark, with a device on USB (expanded) and one on
/// Wi-Fi, to `FERRY_MENU_SNAPSHOTS` (a folder). Off unless that is set: it writes files and
/// checks nothing a test should.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FERRY_MENU_SNAPSHOTS"] != nil))
struct MenuSnapshotTests {
  private static let usb = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "PX8"), manufacturer: "Google", model: "Pixel 8"),
    state: .ready([
      StorageInfo(
        id: StorageID(device: DeviceID(serial: "PX8"), key: "internal"),
        description: "Internal shared storage", capacity: 128_000_000_000, free: 21_000_000_000)
    ]), method: .usbADB)
  private static let wifi = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "S24"), manufacturer: "Samsung", model: "Galaxy S24"),
    state: .ready([
      StorageInfo(
        id: StorageID(device: DeviceID(serial: "S24"), key: "internal"),
        description: "Internal shared storage", capacity: 256_000_000_000, free: 98_000_000_000)
    ]), method: .wifiADB)

  @Test(arguments: [ColorScheme.light, .dark])
  func drawTheMenu(scheme: ColorScheme) async throws {
    let folder = try #require(ProcessInfo.processInfo.environment["FERRY_MENU_SNAPSHOTS"])
    let client = FakeClient(log: CallLog())
    client.setStatus(
      [Self.usb, Self.wifi], adb: .available,
      remembered: [
        RememberedDevice(
          id: Self.wifi.id, name: "Galaxy S24",
          addresses: [try #require(WirelessEndpoint(parsing: "192.168.1.42"))])
      ])
    let model = AppModel(
      client: client, services: FakeServices(log: CallLog()),
      sleep: { _ in throw CancellationError() })
    await model.watchWhileMenuOpen()

    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let view = NSHostingView(
      rootView: MenuContent(model: model)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.appearance = appearance
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    appearance?.performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let name = scheme == .dark ? "task-14-menu-dark.png" : "task-14-menu-light.png"
    try png.write(to: URL(filePath: folder).appending(path: name))
  }
}
