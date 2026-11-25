import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Every problem the menu words from an error, and every fixed problem line, carries the key of
/// its Help entry, so its Help link opens the topic that explains it. Every case of every error
/// is drawn from `HelpLinkCases`, which the compiler keeps exhaustive.
struct HelpLinkTests {
  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])
  static let transportErrors = HelpLinkCases.Transport.allCases.map(HelpLinkCases.sample)
  static let toolFailures = HelpLinkCases.Tool.allCases.flatMap(HelpLinkCases.samples)

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

  /// Every outcome but connected says something, with its entry; connected says nothing.
  @Test(arguments: HelpLinkCases.Outcome.allCases)
  func eachWirelessOutcomeLinksToItsEntry(kind: HelpLinkCases.Outcome) throws {
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.31"))
    let outcome = HelpLinkCases.sample(kind, address: address)
    #expect(HelpLinkCases.kind(of: outcome) == kind)
    let notice = DevicePresentation.notice(for: outcome)
    if kind == .connected {
      #expect(notice == nil)
    } else {
      Self.expectExplained(notice, "\(outcome)")
    }
  }

  /// Each sample is the case it stands for.
  @Test func theSamplesAreTheirCases() {
    for kind in HelpLinkCases.Transport.allCases {
      #expect(HelpLinkCases.kind(of: HelpLinkCases.sample(kind)) == kind)
    }
    for kind in HelpLinkCases.Tool.allCases {
      #expect(HelpLinkCases.samples(kind).allSatisfy { HelpLinkCases.kind(of: $0) == kind })
    }
  }

  @Test @MainActor func theFixedProblemLinesLinkToTheirEntries() {
    for resource in MenuStatusText.all {
      Self.expectExplained(MenuNotice(resource), "\(resource.key)")
    }
    Self.expectExplained(DevicePresentation.waitingLine(for: "192.0.2.31:5555"), "waiting")
    Self.expectExplained(DevicePresentation.terminalFailure, "terminal")
    Self.expectExplained(DevicePresentation.logEnded, "log ended")
    Self.expectExplained(DevicePresentation.saveLogFailure("disk full"), "log not saved")
    let saved = PreservedChangesRow.line(URL(filePath: "/tmp/Unsent"))
    #expect(saved.text == "Unsent changes were saved to /tmp/Unsent")
    Self.expectExplained(saved, "unsent changes")
    let waiting = WaitingChangesRow.line("Phone – SD card")
    #expect(waiting.text == "Phone – SD card: changes wait to be sent. Reconnect it to finish.")
    Self.expectExplained(waiting, "changes waiting")
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

/// Several problems can show at once, so VoiceOver must tell their Help links apart (audit L5).
struct HelpLinkLabelTests {
  @Test @MainActor func eachLinkNamesItsProblem() {
    #expect(
      HelpLinkButton.label(forMessage: "The device was disconnected. Reconnect it, then try again.")
        == "Help: The device was disconnected. Reconnect it, then try again.")
    #expect(
      HelpLinkButton.label(forMessage: "Unsent changes were saved to %@")
        == "Help: Unsent changes were saved to …")
  }
}
