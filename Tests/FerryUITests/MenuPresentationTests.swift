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

  /// The tools, in their groups: capture, sending, developer tools.
  private static let tools: [[Action]] = [
    [.takeScreenshot, .recordScreen], [.sendFile, .installApp],
    [.logcat, .portForwarding, .openInTerminal],
  ]

  /// A state, how the device is attached, whether Ferry remembers it, and its groups.
  struct GroupCase: Sendable {
    let state: DeviceState
    let method: ConnectionMethod
    let remembered: Bool
    let groups: [[Action]]
  }

  private static let groupCases: [GroupCase] = [
    GroupCase(
      state: ready, method: .usbADB, remembered: false, groups: tools + [[.useOverWiFi, .eject]]),
    GroupCase(
      state: ready, method: .usbADB, remembered: true,
      groups: tools + [[.useOverWiFi, .forget, .eject]]),
    GroupCase(
      state: ready, method: .wifiADB, remembered: true, groups: tools + [[.forget, .eject]]),
    GroupCase(state: ready, method: .wifiADB, remembered: false, groups: tools + [[.eject]]),
    GroupCase(
      state: ready, method: .usbFileTransfer, remembered: false, groups: [[.sendFile], [.eject]]),
    GroupCase(
      state: .notSharingFiles, method: .usbFileTransfer, remembered: false,
      groups: [[.howToTurnOnFileTransfer]]),
    GroupCase(state: .notSharingFiles, method: .usbADB, remembered: false, groups: []),
    GroupCase(state: .ejected, method: .usbFileTransfer, remembered: false, groups: [[.mount]]),
    GroupCase(state: .ejected, method: .usbADB, remembered: true, groups: [[.forget, .mount]]),
    GroupCase(state: .busy, method: .usbFileTransfer, remembered: false, groups: [[.checkAgain]]),
    GroupCase(
      state: .failed(.deviceBusy), method: .usbFileTransfer, remembered: false,
      groups: [[.checkAgain]]),
  ]

  /// The rows in groups divided by thin lines: capture, sending, developer tools, then the
  /// device itself (Use over Wi-Fi, Forget, and Eject or the row its state needs). A group
  /// with no rows is left out.
  @Test(arguments: groupCases)
  func eachStateOffersItsActionsInGroups(_ test: GroupCase) {
    #expect(
      DevicePresentation.actionGroups(
        for: Self.attached(test.state, test.method), isRemembered: test.remembered,
        recording: .none)
        == test.groups)
  }

  /// Record Screen while nothing records, Stop Recording while it does, and neither while a
  /// recording is saved or waits for Choose Folder… or Discard: Take Screenshot is then alone in
  /// its group.
  @Test(arguments: [
    (DevicePresentation.RecordingPhase.none, [Action.takeScreenshot, .recordScreen]),
    (.running, [.takeScreenshot, .stopRecording]), (.saving, [.takeScreenshot]),
    (.unsaved, [.takeScreenshot]),
  ])
  func theRecordingRowFollowsTheRecording(
    phase: DevicePresentation.RecordingPhase, capture: [Action]
  ) {
    let groups = DevicePresentation.actionGroups(
      for: Self.attached(Self.ready, .usbADB), isRemembered: false, recording: phase)
    #expect(groups.first == capture)
    #expect(groups.count == 4)
  }

  @Test func rememberedAndOfferRowsOfferTheirPair() {
    #expect(DevicePresentation.rememberedActions == [.connectAgain, .forget])
    #expect(DevicePresentation.offerActions == [.useIt, .ignore])
  }

  @Test(arguments: [
    (Action.takeScreenshot, "Take Screenshot"), (.recordScreen, "Record Screen"),
    (.stopRecording, "Stop Recording"), (.logcat, "Logcat"),
    (.portForwarding, "Port Forwarding"), (.sendFile, "Send File…"),
    (.installApp, "Install App…"), (.openInTerminal, "Open in Terminal"),
    (.useOverWiFi, "Use over Wi-Fi"),
    (.forget, "Forget This Device"), (.howToTurnOnFileTransfer, "How to Turn On File Transfer"),
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

  /// The summary already gives the first storage's free space: the expansion lists storages
  /// only when there are several.
  @Test func theExpansionListsStoragesOnlyWhenThereAreSeveral() {
    let card = StorageInfo(
      id: StorageID(device: DeviceID(serial: "A"), key: "SD card|1"), description: "SD card",
      capacity: 64_000_000_000, free: 10_000_000_000)
    #expect(DevicePresentation.listedStorages(of: Self.attached(Self.ready, .usbADB)).isEmpty)
    #expect(DevicePresentation.listedStorages(of: Self.attached(.ready([]), .usbADB)).isEmpty)
    #expect(
      DevicePresentation.listedStorages(of: Self.attached(.ready([Self.storage, card]), .usbADB))
        == [Self.storage, card])
    #expect(DevicePresentation.listedStorages(of: Self.attached(.ejected, .usbADB)).isEmpty)
  }
}
