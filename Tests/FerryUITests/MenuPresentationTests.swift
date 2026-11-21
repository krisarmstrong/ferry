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
      DevicePresentation.Tile(glyph: .device(.pixel), isActive: true)
    ),
    (ready, .usbFileTransfer, .init(glyph: .device(.pixel), isActive: true)),
    (ready, .wifiADB, .init(glyph: .device(.pixel), isActive: true)),
    (.notSharingFiles, .usbFileTransfer, .init(glyph: .device(.pixel), isActive: false)),
    (.ejected, .usbADB, .init(glyph: .device(.pixel), isActive: false)),
    (.busy, .usbFileTransfer, .init(glyph: .device(.pixel), isActive: false)),
    (.failed(.deviceBusy), .wifiADB, .init(glyph: .device(.pixel), isActive: false)),
  ])
  func theTileIsActiveOnlyWhenReady(
    state: DeviceState, method: ConnectionMethod, tile: DevicePresentation.Tile
  ) {
    #expect(DevicePresentation.tile(of: Self.attached(state, method)) == tile)
  }

  /// The tile draws what kind of device it is, read from what the device reports: NetAlly's
  /// testers by model name, whatever their maker reports; tablets by name or Samsung's tablet
  /// model numbers; Samsung's foldables and other phones and Google's Pixels by their makers;
  /// else a phone.
  @Test(arguments: [
    ("", "EtherScope nXG", DevicePresentation.TileGlyph.device(.etherScope)),
    ("", "EtherScope-nXG", .device(.etherScope)),
    ("NetAlly", "CyberScope", .device(.etherScope)),
    ("", "CyberScope XRF", .device(.etherScope)),
    ("", "LinkRunner 10G", .device(.linkRunner)),
    ("NetAlly", "LinkRunner 100G", .device(.linkRunner)),
    ("freescale", "LinkRunner-100G", .device(.linkRunner)),
    ("NetAlly", "LinkRunner G2", .device(.linkRunner)),
    ("", "LinkRunner AT 4000", .device(.linkRunnerAT)),
    ("NetAlly", "LinkRunner AT 2000", .device(.linkRunnerAT)),
    ("", "AirCheck G3", .device(.airCheck)),
    ("", "NetAlly AirCheck G3", .device(.airCheck)),
    ("NetAlly", "", .device(.tester)),
    ("NetAlly", "Test Accessory", .device(.tester)),
    ("Google", "Pixel 8", .device(.pixel)),
    ("Google", "Pixel 8 Pro", .device(.pixel)),
    ("Google", "Pixel Fold", .device(.pixel)),
    ("Google", "Nexus 5X", .phone),
    ("", "Pixel 8 Pro", .phone),
    ("Samsung", "Galaxy S24", .device(.galaxy)),
    ("samsung", "SM-S921U", .device(.galaxy)),
    ("samsung", "SM-S928U", .device(.galaxy)),
    ("samsung", "SM-A546E", .device(.galaxy)),
    ("samsung", "SM-F946U", .device(.foldable)),
    ("samsung", "SM-F731B", .device(.foldable)),
    ("Samsung", "Galaxy Z Fold5", .device(.foldable)),
    ("Samsung", "Galaxy Z Flip5", .device(.foldable)),
    ("", "", .phone),
    ("Acme", "Widget 3000", .phone),
    ("Google", "Pixel Tablet", .device(.tablet)),
    ("Samsung", "Galaxy Tab S9", .device(.tablet)),
    ("samsung", "SM-X710", .device(.tablet)),
    ("samsung", "SM-T870", .device(.tablet)),
    ("samsung", "SM-P613", .device(.tablet)),
    ("LENOVO", "Lenovo TB-X606F", .device(.tablet)),
    ("LENOVO", "TB3-850F", .device(.tablet)),
    ("Generic", "STB-100", .phone),
    ("Generic", "TB-200", .phone),
    ("Xiaomi", "Mi Pad 5", .device(.tablet)),
    ("HUAWEI", "MatePad 11", .device(.tablet)),
    ("HUAWEI", "MediaPad M5", .device(.tablet)),
    ("Amazon", "KFTRWI", .device(.tablet)),
    ("Amazon", "Fire HD 10", .device(.tablet)),
    ("Motorola", "moto g stylus", .phone),
  ])
  func theTileShowsTheKindOfDevice(
    manufacturer: String, model: String, glyph: DevicePresentation.TileGlyph
  ) {
    let device = AttachedDevice(
      info: DeviceInfo(id: DeviceID(serial: "A"), manufacturer: manufacturer, model: model),
      state: Self.ready, method: .usbADB)
    #expect(DevicePresentation.tile(of: device) == .init(glyph: glyph, isActive: true))
  }

  @Test func rememberedAndOfferTilesAreNeutral() {
    #expect(
      DevicePresentation.rememberedTile == .init(glyph: .symbol("wifi.slash"), isActive: false))
    #expect(DevicePresentation.offerTile == .init(glyph: .symbol("wifi"), isActive: false))
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
    var names = [DevicePresentation.TileGlyph.phoneSymbol]
    for case .symbol(let name) in [
      DevicePresentation.rememberedTile.glyph, DevicePresentation.offerTile.glyph,
    ] {
      names.append(name)
    }
    #expect(names.count == 3)
    for name in names {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
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
