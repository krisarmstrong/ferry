import AppKit
import DeviceKit
import FerryIPC
import Foundation
import Observation
import SwiftUI
import Testing

@testable import FerryUI

/// Draws the menu offscreen, in light and dark, with a tester on USB (opened, with its known
/// ports' details, one not connected, its rows in their groups and Port Forwarding open on one
/// forward), a phone on Wi-Fi and a tablet not sharing files; once more with Pair with Code
/// open; and with Increase Contrast, light and dark. It must come out 320 pt wide and show
/// something besides its background. With `FERRY_MENU_SNAPSHOTS` naming a folder, the images
/// are also written there as `menu-light.png`, `menu-dark.png`, `menu-pair.png`,
/// `menu-contrast-light.png` and `menu-contrast-dark.png`.
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
  private static let tablet = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "TAB"), manufacturer: "Samsung", model: "Galaxy Tab S9"),
    state: .notSharingFiles, method: .usbFileTransfer)

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

  /// What the menu shows besides the expanded device's details.
  private enum Shown {
    case forwards
    case pairForm
  }

  private func drawnMenu(
    _ appearanceName: NSAppearance.Name, contrast: ColorSchemeContrast = .standard,
    showing shown: Shown = .forwards
  ) async throws -> NSBitmapImageRep {
    let client = FakeClient(log: CallLog())
    client.setStatus(
      [Self.usb, Self.wifi, Self.tablet], adb: .available,
      connectedAddresses: [Self.wifi.id: try #require(WirelessEndpoint(parsing: "192.0.2.42"))])
    client.infoReply.withLock { $0 = .deviceInfo(Self.details) }
    client.forwardList.withLock { $0 = [PortForward(local: 8080, remote: 80)] }
    // The menu stays open while it is drawn: a sleep that throws would close it, and closing
    // cancels the details read the drawing waits for.
    let sleeps = HeldSleeps()
    let model = AppModel(
      client: client, services: FakeServices(log: CallLog()), sleep: sleeps.sleep)
    // Launching reads the login item, which the fake has on: Open at Login shows its checkmark.
    await model.launch()
    #expect(model.opensAtLogin)
    // A form open when the menu opens stays open, so it is opened before the menu draws.
    if shown == .pairForm {
      model.toggleNetworkForm(.code)
      model.networkForm?.address = "192.0.2.31:37123"
    }
    let appearance = NSAppearance(named: appearanceName)
    let view = NSHostingView(
      rootView: MenuContent(model: model)
        // Increase Contrast, as the system sets it: AppKit offers no high-contrast appearance
        // to draw with unless the setting is on.
        .environment(\._colorSchemeContrast, contrast)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.appearance = appearance
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    // The view's own task collapses every row as the menu opens and reads the first status,
    // then waits for its next refresh: the device is opened after that, as a user would.
    #expect(await sleeps.waitForSleeper())
    model.toggleExpansion(.device(Self.usb.id))
    // Then its details are read.
    while model.shownDetails(of: Self.usb.id) != .loaded(Self.details) {
      await Self.change(of: model) { _ = $0.details }
    }
    if shown == .forwards {
      await model.toggleForwards(of: Self.usb.id)
      #expect(model.openForwards(of: Self.usb.id)?.forwards.count == 1)
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

  private func save(_ bitmap: NSBitmapImageRep, as name: String) throws {
    guard let folder = ProcessInfo.processInfo.environment["FERRY_MENU_SNAPSHOTS"] else { return }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(filePath: folder).appending(path: name))
  }

  @Test(arguments: [
    (NSAppearance.Name.aqua, ColorSchemeContrast.standard, "menu-light.png"),
    (.darkAqua, .standard, "menu-dark.png"),
    (.aqua, .increased, "menu-contrast-light.png"),
    (.darkAqua, .increased, "menu-contrast-dark.png"),
  ])
  func theMenuDraws(
    appearance: NSAppearance.Name, contrast: ColorSchemeContrast, file: String
  ) async throws {
    let bitmap = try await drawnMenu(appearance, contrast: contrast)
    #expect(bitmap.size.width == 320)
    // Header, three devices with one expanded with its details, the forms and the footer.
    #expect(bitmap.size.height > 500)
    #expect(drawnPixels(bitmap) > 1_000)
    try save(bitmap, as: file)
  }

  @Test func theMenuDrawsWithPairWithCodeOpen() async throws {
    let bitmap = try await drawnMenu(.aqua, showing: .pairForm)
    #expect(bitmap.size.width == 320)
    // Everything from the header to Quit Ferry, with the form's two fields and hint.
    #expect(bitmap.size.height > 700)
    #expect(drawnPixels(bitmap) > 1_000)
    try save(bitmap, as: "menu-pair.png")
  }

  /// Every tile, active and not, in light and dark: the kinds of device, then a remembered
  /// device and an offered address. Written as `device-tiles.png`.
  @Test func theDeviceTilesDraw() throws {
    let glyphs: [DevicePresentation.TileGlyph] = [
      .tester, .phone, .tablet, .symbol("wifi.slash"), .symbol("wifi"),
    ]
    let tiles = VStack(spacing: 0) {
      ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
        VStack(spacing: 10) {
          ForEach([true, false], id: \.self) { active in
            HStack(spacing: 14) {
              ForEach(glyphs.indices, id: \.self) { index in
                DeviceTile(tile: .init(glyph: glyphs[index], isActive: active))
              }
            }
          }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
      }
    }
    let renderer = ImageRenderer(content: tiles)
    renderer.scale = 4
    let image = try #require(renderer.cgImage)
    let bitmap = NSBitmapImageRep(cgImage: image)
    #expect(drawnPixels(bitmap) > 1_000)
    try save(bitmap, as: "device-tiles.png")
  }
}
