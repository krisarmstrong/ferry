import AppKit
import DeviceKit
import FerryIPC
import Foundation
import Observation
import SwiftUI
import Testing

@testable import FerryUI

/// Draws the menu offscreen, in light and dark, with a device on USB (expanded) and one on
/// Wi-Fi: it must come out 320 pt wide and show something besides its background. With
/// `FERRY_MENU_SNAPSHOTS` naming a folder, the images are also written there as
/// `menu-light.png` and `menu-dark.png`.
@MainActor
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

  private func drawnMenu(_ scheme: ColorScheme) async throws -> NSBitmapImageRep {
    let client = FakeClient(log: CallLog())
    client.setStatus(
      [Self.usb, Self.wifi], adb: .available,
      connectedAddresses: [Self.wifi.id: try #require(WirelessEndpoint(parsing: "192.0.2.42"))])
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
    // The view's own task resets the expansion as the menu opens; its first status opens the
    // first ready device again.
    while model.expansion.expanded == nil {
      await Self.change(of: model)
    }
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    appearance?.performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    return bitmap
  }

  /// Returns once the model's expansion next changes.
  private static func change(of model: AppModel) async {
    await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
      withObservationTracking {
        _ = model.expansion
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
    // Header, two devices with one expanded, the forms and the footer.
    #expect(bitmap.size.height > 400)
    #expect(drawnPixels(bitmap) > 1_000)
    guard let folder = ProcessInfo.processInfo.environment["FERRY_MENU_SNAPSHOTS"] else { return }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let name = scheme == .dark ? "menu-dark.png" : "menu-light.png"
    try png.write(to: URL(filePath: folder).appending(path: name))
  }
}
