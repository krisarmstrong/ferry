import AppKit
import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// What each menu row shows and offers, in the Control Center layout.
struct MenuPresentationTests {
  private static func attached(
    _ state: DeviceState, _ method: ConnectionMethod
  ) -> AttachedDevice {
    AttachedDevice(
      info: DeviceInfo(id: DeviceID(serial: "A"), manufacturer: "Google", model: "Pixel 8"),
      state: state, method: method)
  }

  private static let storage = StorageInfo(
    id: StorageID(device: DeviceID(serial: "A"), key: "Internal shared storage|0"),
    description: "Internal shared storage", capacity: 128_000_000_000, free: 21_000_000_000)
  private static let ready = DeviceState.ready([storage])
  private static let address = WirelessEndpoint(parsing: "192.0.2.31")

  // MARK: Summary

  @Test(arguments: [
    (ready, ConnectionMethod.usbADB, nil as WirelessEndpoint?, "USB · 21 GB free"),
    (ready, .usbFileTransfer, nil, "USB · 21 GB free"),
    (.ready([]), .usbADB, nil, "USB · Ready"),
    (ready, .wifiADB, address, "Wi-Fi · 192.0.2.31"),
    (ready, .wifiADB, WirelessEndpoint(parsing: "192.0.2.31:37000"), "Wi-Fi · 192.0.2.31:37000"),
    (ready, .wifiADB, nil, "Wi-Fi · 21 GB free"),
    (.ready([]), .wifiADB, nil, "Wi-Fi · Ready"),
    (.notSharingFiles, .usbFileTransfer, nil, "Not sharing files"),
    (.notSharingFiles, .usbADB, nil, "Waiting for Allow"),
    (.ejected, .usbFileTransfer, nil, "Ejected"),
    (.busy, .usbFileTransfer, nil, "In use by another app"),
    (.failed(.deviceBusy), .usbFileTransfer, nil, "Can't open"),
  ])
  func theSummaryIsTheMethodWithFreeSpaceOrAddressOrTheState(
    state: DeviceState, method: ConnectionMethod, address: WirelessEndpoint?, text: String
  ) {
    #expect(
      DevicePresentation.summary(of: Self.attached(state, method), address: address) == text)
  }

  @Test func aRememberedDeviceIsNotNearby() {
    #expect(DevicePresentation.rememberedSummary == "Remembered · not nearby")
  }

  @Test func anOfferIsSummarisedByItsAddressEscaped() throws {
    let offer = UnconfirmedAddress(
      address: try #require(WirelessEndpoint(parsing: "192.0.2.40")), id: DeviceID(serial: "B"),
      name: "Pixel 8")
    #expect(DevicePresentation.offerSummary(offer) == "192.0.2.40")
  }

  @Test func theRowReadsAsOneElement() {
    #expect(
      DevicePresentation.rowLabel(name: "Pixel 8", summary: "USB · Ready") == "Pixel 8, USB · Ready"
    )
  }

  // MARK: Tile

  @Test(arguments: [
    (
      ready, ConnectionMethod.usbADB,
      DevicePresentation.Tile(symbol: "cable.connector", isActive: true)
    ),
    (ready, .usbFileTransfer, .init(symbol: "cable.connector", isActive: true)),
    (ready, .wifiADB, .init(symbol: "wifi", isActive: true)),
    (.notSharingFiles, .usbFileTransfer, .init(symbol: "cable.connector", isActive: false)),
    (.ejected, .usbADB, .init(symbol: "cable.connector", isActive: false)),
    (.busy, .usbFileTransfer, .init(symbol: "cable.connector", isActive: false)),
    (.failed(.deviceBusy), .wifiADB, .init(symbol: "wifi", isActive: false)),
  ])
  func theTileIsActiveOnlyWhenReady(
    state: DeviceState, method: ConnectionMethod, tile: DevicePresentation.Tile
  ) {
    #expect(DevicePresentation.tile(of: Self.attached(state, method)) == tile)
  }

  @Test func rememberedAndOfferTilesAreNeutral() {
    #expect(DevicePresentation.rememberedTile == .init(symbol: "wifi.slash", isActive: false))
    #expect(DevicePresentation.offerTile == .init(symbol: "wifi", isActive: false))
  }

  // MARK: Actions

  typealias Action = DevicePresentation.MenuAction

  private static let tools: [Action] = [
    .takeScreenshot, .recordScreen, .logcat, .deviceInfo, .portForwarding, .sendFile, .installApp,
    .openShell,
  ]

  @Test(
    arguments: [
      (ready, ConnectionMethod.usbADB, false, tools + [.useOverWiFi, .eject]),
      (ready, .usbADB, true, tools + [.useOverWiFi, .forget, .eject]),
      (ready, .wifiADB, true, tools + [.forget, .eject]),
      (ready, .wifiADB, false, tools + [.eject]),
      (ready, .usbFileTransfer, false, [.sendFile, .eject]),
      (.notSharingFiles, .usbFileTransfer, false, [.howToTurnOnFileTransfer]),
      (.notSharingFiles, .usbADB, false, [Action]()),
      (.ejected, .usbFileTransfer, false, [.mount]),
      (.ejected, .usbADB, true, [.forget, .mount]),
      (.busy, .usbFileTransfer, false, [.checkAgain]),
      (.failed(.deviceBusy), .usbFileTransfer, false, [.checkAgain]),
    ])
  func eachStateOffersItsActionsInMenuOrder(
    state: DeviceState, method: ConnectionMethod, remembered: Bool, actions: [Action]
  ) {
    #expect(
      DevicePresentation.actions(
        for: Self.attached(state, method), isRemembered: remembered, recording: .none)
        == actions)
  }

  /// Record Screen while nothing records, Stop Recording while it does, and neither while a
  /// recording is saved or waits for Choose Folder… or Discard.
  @Test(arguments: [
    (DevicePresentation.RecordingPhase.none, Action?.some(.recordScreen)),
    (.running, .stopRecording), (.saving, nil), (.unsaved, nil),
  ])
  func theRecordingRowFollowsTheRecording(phase: DevicePresentation.RecordingPhase, row: Action?) {
    let actions = DevicePresentation.actions(
      for: Self.attached(Self.ready, .usbADB), isRemembered: false, recording: phase)
    #expect(
      actions.filter { $0 == .recordScreen || $0 == .stopRecording } == (row.map { [$0] } ?? []))
  }

  @Test func rememberedAndOfferRowsOfferTheirPair() {
    #expect(DevicePresentation.rememberedActions == [.connectAgain, .forget])
    #expect(DevicePresentation.offerActions == [.useIt, .ignore])
  }

  @Test(arguments: [
    (Action.takeScreenshot, "Take Screenshot"), (.recordScreen, "Record Screen"),
    (.stopRecording, "Stop Recording"), (.logcat, "Logcat"), (.deviceInfo, "Device Info"),
    (.portForwarding, "Port Forwarding"), (.sendFile, "Send File…"),
    (.installApp, "Install App…"), (.openShell, "Open Shell"), (.useOverWiFi, "Use over Wi-Fi"),
    (.forget, "Forget"), (.howToTurnOnFileTransfer, "How to Turn On File Transfer"),
    (.mount, "Mount"), (.checkAgain, "Check Again"), (.eject, "Eject"),
    (.connectAgain, "Connect Again"), (.useIt, "Use It"), (.ignore, "Ignore"),
  ])
  func eachActionHasATitleCaseLabel(action: Action, title: String) {
    #expect(String(localized: action.title) == title)
  }

  /// A misspelt symbol draws nothing.
  @Test(arguments: Action.allCases)
  func eachActionSymbolExists(action: Action) {
    #expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil)
  }

  @Test func eachTileSymbolExists() {
    let tiles =
      [DevicePresentation.rememberedTile, DevicePresentation.offerTile]
      + ConnectionMethod.allCases.map { DevicePresentation.tile(of: Self.attached(Self.ready, $0)) }
    for tile in tiles {
      #expect(NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil) != nil)
    }
  }

  @Test(arguments: [
    (false, false, false, DevicePresentation.RecordingPhase.running),
    (true, false, false, .saving), (false, true, false, .saving), (false, true, true, .unsaved),
  ])
  func theRecordingPhaseFollowsTheAgent(
    stopping: Bool, finished: Bool, unsaved: Bool, phase: DevicePresentation.RecordingPhase
  ) {
    let recording = ActiveRecording(
      device: DeviceID(serial: "A"), started: .now, stopping: stopping, finished: finished)
    #expect(DevicePresentation.recordingPhase(recording, unsaved: unsaved) == phase)
  }

  @Test func noRecordingIsNone() {
    #expect(DevicePresentation.recordingPhase(nil, unsaved: false) == .none)
  }

  /// The offer's name came from the device: escaped, and never blank.
  @Test(arguments: [("Pixel 8", "Pixel 8"), ("", "Unknown device"), ("Pixel\u{7}", "Pixel\\u{7}")])
  func anOfferIsNamedSafely(name: String, shown: String) throws {
    let offer = UnconfirmedAddress(
      address: try #require(WirelessEndpoint(parsing: "192.0.2.40")), id: DeviceID(serial: "B"),
      name: name)
    #expect(DevicePresentation.offerName(offer) == shown)
  }
}
