import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Every problem the menu words from an error, and every fixed problem line, carries the key of
/// its Help entry, so its Help link opens the topic that explains it. Each case of each error is
/// listed: a case added to an enum must be added here.
struct HelpLinkTests {
  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])
  private static let path = RemotePath.root

  static let transportErrors: [TransportError] = [
    .noDeviceConnected, .deviceNotFound(DeviceID(serial: "A")), .noStorage,
    .storageNotFound("internal"), .deviceBusy, .deviceLocked, .deviceDisconnected,
    .notFound(path), .unknownItem, .alreadyExists(path), .invalidName("a:b"),
    .unsupported("move"), .insufficientSpace(needed: 2, free: 1),
    .fileTooLargeForStorage(size: 5_000_000_000), .sizeMismatch(expected: 2, actual: 1),
    .downloadSizeMismatch(listed: 2, received: 1),
    .nameChangedByDevice(requested: "a", actual: "b"), .directoryNotEmpty(path),
    .changedOnDevice(path), .macDiskFull(needed: 2, free: 1), .folderTooDeep(path),
    .readOnly(path), .cancelled, .agentNotResponding, .io("broken pipe"),
  ]

  static let toolFailures: [ToolFailure] = [
    .notOverADB, .notAnAPK, .apkTooLarge, .installFailed("INSTALL_FAILED_OLDER_SDK"),
    .installFailed("INSTALL_PARSE_FAILED_NO_CERTIFICATES"), .installFailed("SOMETHING_NEW"),
    .alreadyRecording, .notRecording, .noImage, .recordingFailed(""),
    .recordingFailed("encoder died"), .recordingTooLarge, .recordingStalled, .recordingBusy,
    .cannotSave, .invalidPort, .forwardFailed("Address already in use"), .forwardNotFound,
    .adbNotFound,
  ]

  static let wirelessFailures: [WirelessFailure] = [
    .adbUnavailable, .notOverUSB, .notRemembered, .noConnectService, .otherDevice,
    .unidentified, .pairingNeedsAddress, .offerChanged, .deviceInUse, .adb("refused"),
  ]

  private static func expectExplained(_ notice: MenuNotice?, _ comment: Comment) {
    let key = notice?.help ?? ""
    #expect(help.topic(forMessage: key) != nil, comment)
  }

  @Test(arguments: transportErrors)
  func eachTransportErrorLinksToItsEntry(error: TransportError) {
    let notice = DevicePresentation.notice(for: error)
    #expect(notice.text == DevicePresentation.message(for: error))
    Self.expectExplained(notice, "\(error)")
  }

  @Test(arguments: toolFailures)
  func eachToolFailureLinksToItsEntry(failure: ToolFailure) {
    let notice = DevicePresentation.notice(for: failure)
    #expect(notice.text == DevicePresentation.message(for: failure))
    Self.expectExplained(notice, "\(failure)")
  }

  @Test(arguments: wirelessFailures)
  func eachWirelessFailureLinksToItsEntry(failure: WirelessFailure) {
    Self.expectExplained(DevicePresentation.notice(for: .failed(failure)), "\(failure)")
  }

  @Test func theOtherWirelessOutcomesLinkToTheirEntries() throws {
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.31"))
    for outcome: WirelessOutcome in [
      .awaitingAllow(address), .needsConfirmation(address), .needsNetwork,
    ] {
      Self.expectExplained(DevicePresentation.notice(for: outcome), "\(outcome)")
    }
    #expect(DevicePresentation.notice(for: .connected) == nil)
  }

  @Test func theFixedProblemLinesLinkToTheirEntries() {
    for resource in MenuStatusText.all {
      Self.expectExplained(MenuNotice(resource), "\(resource.key)")
    }
    Self.expectExplained(DevicePresentation.waitingLine(for: "192.0.2.31:5555"), "waiting")
    Self.expectExplained(DevicePresentation.terminalFailure, "terminal")
    let saved = PreservedChangesRow.line(URL(filePath: "/tmp/Unsent"))
    #expect(saved.text == "Unsent changes were saved to /tmp/Unsent")
    Self.expectExplained(saved, "unsent changes")
  }

  /// The model's own failures, shown in the menu's error row.
  @MainActor
  @Test func openAtLoginFailureLinksToItsEntry() async {
    let log = CallLog()
    let services = FakeServices(log: log)
    services.failLoginItem = true
    let model = AppModel(client: FakeClient(log: log), services: services)
    model.requestOpensAtLogin(true)
    await model.loginItemSettled()
    Self.expectExplained(model.actionError, "open at login")
  }
}
