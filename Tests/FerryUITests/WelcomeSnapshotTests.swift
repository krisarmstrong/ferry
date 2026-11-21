import AppKit
import DeviceKit
import FerryIPC
import Foundation
import SwiftUI
import Testing

@testable import FerryUI

/// Draws the welcome offscreen, in light and dark: on a new Mac with nothing connected; with a
/// phone connected, Ferry still off in Finder and adb missing; and once everything is in place.
/// Each must come out 400 pt wide and show something besides its background. With
/// `FERRY_WELCOME_SNAPSHOTS` naming a folder, the images are also written there as
/// `welcome-<state>-<light|dark>.png`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WelcomeSnapshotTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static let phone = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "P1"), manufacturer: "Google", model: "Pixel 8"),
    state: .ready([]), method: .usbFileTransfer)

  enum Shown: String, CaseIterable {
    case first, steps, ready
  }

  private func model(showing shown: Shown) async -> AppModel {
    let log = CallLog()
    let client = FakeClient(log: log)
    let services = FakeServices(log: log)
    services.startedAgent = nil
    switch shown {
    case .first:
      client.setStatus([], provider: .noDomains, adb: .available)
    case .steps:
      client.setStatus([], provider: .noDomains, adb: .notInstalled)
    case .ready:
      client.setStatus([Self.phone], provider: .enabled, adb: .available)
    }
    // The window's own refreshes end at once: the drawing shows the status set here.
    let model = AppModel(
      client: client, services: services, sleep: { _ in throw CancellationError() })
    await model.launch()
    switch shown {
    case .first:
      break
    case .steps:
      // The phone connects while the window is open; Finder has its location, still off.
      client.setStatus([Self.phone], provider: .disabled, adb: .notInstalled)
      await model.refresh()
    case .ready:
      model.showWelcome()
    }
    return model
  }

  private func drawn(_ shown: Shown, _ appearanceName: NSAppearance.Name) async throws
    -> NSBitmapImageRep
  {
    let model = await model(showing: shown)
    #expect(model.isWelcomePresented)
    let icon = try #require(NSImage(contentsOf: Self.root.appending(path: "Design/Icon/Ferry.png")))
    let appearance = NSAppearance(named: appearanceName)
    let view = NSHostingView(
      rootView: WelcomeView(model: model, icon: icon)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.appearance = appearance
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    appearance?.performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    return bitmap
  }

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

  @Test(arguments: Shown.allCases, [NSAppearance.Name.aqua, .darkAqua])
  func theWelcomeDraws(shown: Shown, appearance: NSAppearance.Name) async throws {
    let bitmap = try await drawn(shown, appearance)
    #expect(bitmap.size.width == 400)
    #expect(drawnPixels(bitmap) > 1000)
    guard let folder = ProcessInfo.processInfo.environment["FERRY_WELCOME_SNAPSHOTS"] else {
      return
    }
    let name = "welcome-\(shown.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(filePath: folder).appending(path: name))
  }

  /// The steps the drawings show, so a change in what is listed shows up here first.
  @Test func theDrawnStatesListTheseSteps() async {
    #expect(
      await model(showing: .first).welcomeSteps == [
        WelcomeStepLine(step: .connectDevice, isDone: false)
      ])
    #expect(
      await model(showing: .steps).welcomeSteps == [
        WelcomeStepLine(step: .connectDevice, isDone: true),
        WelcomeStepLine(step: .turnOnInFinder, isDone: false),
        WelcomeStepLine(step: .getPlatformTools, isDone: false),
      ])
    let ready = await model(showing: .ready)
    #expect(ready.isWelcomeComplete)
    #expect(
      ready.welcomeSteps == [
        WelcomeStepLine(step: .connectDevice, isDone: true),
        WelcomeStepLine(step: .turnOnInFinder, isDone: true),
      ])
  }
}
