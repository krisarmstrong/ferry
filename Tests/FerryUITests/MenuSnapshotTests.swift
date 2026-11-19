import AppKit
import DeviceKit
import FerryIPC
import Foundation
import Observation
import SwiftUI
import Testing

@testable import FerryUI

/// Draws the menu offscreen, in light and dark, with a device on USB (expanded, with its known
/// ports' details, one not connected) and one on Wi-Fi: it must come out 320 pt wide and show
/// something besides its background. With
/// `FERRY_MENU_SNAPSHOTS` naming a folder, the images are also written there as
/// `menu-light.png` and `menu-dark.png`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MenuSnapshotTests {
  private static let usb = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "ES1"), manufacturer: "", model: "EtherScope-nXG"),
    state: .ready([
      StorageInfo(
        id: StorageID(device: DeviceID(serial: "ES1"), key: "internal"),
        description: "Internal shared storage", capacity: 128_000_000_000, free: 21_000_000_000)
    ]), method: .usbADB)
  private static let wifi = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "S24"), manufacturer: "Samsung", model: "Galaxy S24"),
    state: .ready([
      StorageInfo(
        id: StorageID(device: DeviceID(serial: "S24"), key: "internal"),
        description: "Internal shared storage", capacity: 256_000_000_000, free: 98_000_000_000)
    ]), method: .wifiADB)

  /// What the expanded device says: Wired Management (`eth0`) has no address.
  private static let details = AndroidDeviceInfo(
    model: "EtherScope-nXG", androidVersion: "8.1.0", build: "OPM1", serial: "ES1",
    battery: .init(level: 100, state: .full),
    addresses: [
      .init(interface: "wlan0", address: "192.0.2.159"),
      .init(interface: "wlan0", address: "2001:db8::159"),
      .init(interface: "eno0", address: "192.0.2.156"),
      .init(interface: "wax0", address: "192.0.2.160"),
    ], storage: nil)

  private func drawnMenu(_ scheme: ColorScheme) async throws -> NSBitmapImageRep {
    let client = FakeClient(log: CallLog())
    client.setStatus(
      [Self.usb, Self.wifi], adb: .available,
      connectedAddresses: [Self.wifi.id: try #require(WirelessEndpoint(parsing: "192.0.2.42"))])
    client.infoReply.withLock { $0 = .deviceInfo(Self.details) }
    // The menu stays open while it is drawn: a sleep that throws would close it, and closing
    // cancels the details read the drawing waits for.
    let model = AppModel(
      client: client, services: FakeServices(log: CallLog()), sleep: HeldSleeps().sleep)
    await model.refresh()
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let view = NSHostingView(
      rootView: MenuContent(model: model)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.appearance = appearance
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    // The view's own task resets the expansion as the menu opens; its first status opens the
    // first ready device again.
    while model.expansion.expanded == nil {
      await Self.change(of: model) { _ = $0.expansion }
    }
    // Then its details are read.
    while model.shownDetails(of: Self.usb.id) != .loaded(Self.details) {
      await Self.change(of: model) { _ = $0.details }
    }
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    appearance?.performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    return bitmap
  }

  /// Returns once what `read` reads of the model next changes.
  private static func change(of model: AppModel, _ read: @escaping (AppModel) -> Void) async {
    await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
      withObservationTracking {
        read(model)
      } onChange: {
        changed.resume()
      }
    }
  }

  /// How many pixels differ from the top-left one, the window background.
  private func drawnPixels(_ bitmap: NSBitmapImageRep) -> Int {
    guard let background = bitmap.colorAt(x: 0, y: 0) else { return 0 }
    var count = 0
    for row in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
      for column in stride(from: 0, to: bitmap.pixelsWide, by: 2)
      where bitmap.colorAt(x: column, y: row) != background {
        count += 1
      }
    }
    return count
  }

  @Test(arguments: [ColorScheme.light, .dark])
  func theMenuDraws(scheme: ColorScheme) async throws {
    let bitmap = try await drawnMenu(scheme)
    #expect(bitmap.size.width == 320)
    // Header, two devices with one expanded with its details, the forms and the footer.
    #expect(bitmap.size.height > 500)
    #expect(drawnPixels(bitmap) > 1_000)
    guard let folder = ProcessInfo.processInfo.environment["FERRY_MENU_SNAPSHOTS"] else { return }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let name = scheme == .dark ? "menu-dark.png" : "menu-light.png"
    try png.write(to: URL(filePath: folder).appending(path: name))
  }
}
