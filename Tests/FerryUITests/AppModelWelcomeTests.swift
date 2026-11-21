import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryUI

/// The welcome: shown once, on the first run, with the steps still needed; never again once it
/// is complete or closed; reopened from Help.
@MainActor
struct AppModelWelcomeTests {
  private let log = CallLog()

  private static let phone = DeviceInfo(
    id: DeviceID(serial: "P1"), manufacturer: "Google", model: "Pixel 8")
  private static let ready = AttachedDevice(info: phone, state: .ready([]), method: .usbADB)
  private static let notSharing = AttachedDevice(
    info: phone, state: .notSharingFiles, method: .usbFileTransfer)

  /// Services as on a Mac that has never run Ferry: no agent started before.
  private func firstRun() -> FakeServices {
    let services = FakeServices(log: log)
    services.startedAgent = nil
    return services
  }

  private func lines(_ model: AppModel) -> [WelcomeStepLine] {
    model.welcomeSteps
  }

  @Test func aFirstRunWithNoDeviceOpensTheWelcomeOnce() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains, adb: .available)
    let services = firstRun()
    let model = AppModel(client: client, services: services)
    await model.launch()

    #expect(model.isWelcomePresented)
    #expect(model.takeWelcomeOpenRequest())
    #expect(!model.takeWelcomeOpenRequest())
    #expect(lines(model) == [WelcomeStepLine(step: .connectDevice, isDone: false)])
    #expect(!model.isWelcomeComplete)
    #expect(services.marks.isEmpty)
  }

  /// A Mac that ran Ferry before this version is not new to it.
  @Test func anExistingUserIsNeverShownIt() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains)
    let services = FakeServices(log: log)
    let model = AppModel(client: client, services: services)
    await model.launch()

    #expect(!model.isWelcomePresented)
    #expect(!model.takeWelcomeOpenRequest())
    #expect(services.marks.contains(.welcomeFinished))
  }

  /// Everything is already in place: there is nothing to walk through.
  @Test func aFirstRunAlreadySetUpIsRecordedWithoutShowing() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.ready], provider: .enabled, adb: .available)
    let services = firstRun()
    let model = AppModel(client: client, services: services)
    await model.launch()

    #expect(!model.isWelcomePresented)
    #expect(services.marks.contains(.welcomeFinished))
  }

  @Test func onceFinishedItNeverShowsAgain() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains)
    let services = firstRun()
    services.marks = [.welcomeFinished]
    let model = AppModel(client: client, services: services)
    await model.launch()

    #expect(!model.isWelcomePresented)
  }

  /// Until the agent answers nothing is decided: not shown, not recorded. Its first answer
  /// decides.
  @Test func itWaitsForTheAgentsFirstAnswer() async {
    let services = firstRun()
    let model = AppModel(client: StartingClient(failures: 1), services: services)
    model.noteFirstRun()
    _ = await model.readStatus()
    #expect(model.agent == .unreachable)
    #expect(!model.isWelcomePresented)
    #expect(services.marks.isEmpty)

    _ = await model.readStatus()
    #expect(model.isWelcomePresented)
  }

  /// Closing the window, by Not Now, Done or its close button, finishes it.
  @Test func closingFinishesIt() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains)
    let services = firstRun()
    let model = AppModel(client: client, services: services)
    await model.launch()
    #expect(model.isWelcomePresented)

    model.welcomeClosed()
    #expect(!model.isWelcomePresented)
    #expect(services.marks.contains(.welcomeFinished))

    // The next launch, on the same Mac.
    services.startedAgent = nil
    let next = AppModel(client: client, services: services)
    await next.launch()
    #expect(!next.isWelcomePresented)
  }

  /// The window follows the status: a step done is ticked, a step that turns up is added, and
  /// once a device is in Finder it is complete, recorded while it is still open.
  @Test func theStepsFollowTheStatus() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains, adb: .notInstalled)
    let services = firstRun()
    let model = AppModel(client: client, services: services)
    await model.launch()
    #expect(
      lines(model) == [
        WelcomeStepLine(step: .connectDevice, isDone: false),
        WelcomeStepLine(step: .getPlatformTools, isDone: false),
      ])

    client.setStatus([Self.ready], provider: .disabled, adb: .notInstalled)
    await model.refresh()
    #expect(
      lines(model) == [
        WelcomeStepLine(step: .connectDevice, isDone: true),
        WelcomeStepLine(step: .turnOnInFinder, isDone: false),
        WelcomeStepLine(step: .getPlatformTools, isDone: false),
      ])
    #expect(!services.marks.contains(.welcomeFinished))

    client.setStatus([Self.ready], provider: .enabled, adb: .notInstalled)
    await model.refresh()
    #expect(model.isWelcomeComplete)
    #expect(model.isWelcomePresented)
    #expect(lines(model).filter(\.isDone).map(\.step) == [.connectDevice, .turnOnInFinder])
    #expect(services.marks.contains(.welcomeFinished))
  }

  /// A device that comes and goes while the window is open does not take back a tick.
  @Test func aStepDoneStaysDoneInTheList() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains, adb: .available)
    let model = AppModel(client: client, services: firstRun())
    await model.launch()
    client.setStatus([Self.ready], provider: .noDomains, adb: .available)
    await model.refresh()
    #expect(lines(model) == [WelcomeStepLine(step: .connectDevice, isDone: true)])
    client.setStatus([], provider: .noDomains, adb: .available)
    await model.refresh()
    #expect(lines(model) == [WelcomeStepLine(step: .connectDevice, isDone: false)])
  }

  /// Help's Show Welcome Window opens it again, whatever was recorded, and closing it again
  /// leaves it finished: reopening never makes it show by itself.
  @Test func helpReopensIt() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.ready], provider: .disabled, adb: .available)
    let services = FakeServices(log: log)
    services.marks = [.welcomeFinished]
    let model = AppModel(client: client, services: services)
    await model.launch()
    #expect(!model.isWelcomePresented)

    model.showWelcome()
    #expect(model.isWelcomePresented)
    #expect(model.takeWelcomeOpenRequest())
    #expect(
      lines(model) == [
        WelcomeStepLine(step: .connectDevice, isDone: true),
        WelcomeStepLine(step: .turnOnInFinder, isDone: false),
      ])
    model.welcomeClosed()
    #expect(services.marks == [.welcomeFinished])

    services.startedAgent = nil
    let next = AppModel(client: client, services: services)
    await next.launch()
    #expect(!next.isWelcomePresented)
  }

  /// The welcome's own Connect a device step carries the setup guide's help: the guide does not
  /// also open by itself on the first run.
  @Test func theGuideWaitsWhileTheWelcomeIsUp() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.notSharing], provider: .noDomains, adb: .available)
    let model = AppModel(client: client, services: firstRun())
    await model.launch()
    #expect(model.isWelcomePresented)
    #expect(!model.isGuidePresented)

    client.setStatus([], provider: .noDomains, adb: .available)
    await model.refresh()
    model.considerEmptyGuide(openFor: .seconds(30))
    #expect(!model.isGuidePresented)

    // Closed, the menu's empty guide works as before.
    model.welcomeClosed()
    model.considerEmptyGuide(openFor: .seconds(30))
    #expect(model.isGuidePresented)
  }

  /// A device that needed its guide while the welcome was up still gets it once it closes.
  @Test func aDeviceSeenDuringTheWelcomeGetsItsGuideAfter() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.notSharing], provider: .noDomains, adb: .available)
    let model = AppModel(client: client, services: firstRun())
    await model.launch()
    #expect(!model.isGuidePresented)
    model.welcomeClosed()
    await model.refresh()
    #expect(model.isGuidePresented)
  }

  /// Its How to Connect opens the guide on the device attached, or the model picker.
  @Test func theConnectStepOpensTheGuide() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.notSharing], provider: .noDomains, adb: .available)
    let model = AppModel(client: client, services: firstRun())
    await model.launch()
    model.showWelcomeGuide(topic: .usbDebugging)
    #expect(model.isGuidePresented)
    #expect(model.guideTopic == .usbDebugging)
    #expect(model.guideFamily == nil)
  }

  @Test func watchingWhileOpenRefreshesUntilCancelled() async {
    let sleeps = Mutex(0)
    let model = AppModel(
      client: FakeClient(log: log), services: FakeServices(log: log),
      sleep: { _ in
        let count = sleeps.withLock { count in
          count += 1
          return count
        }
        if count > 3 { throw CancellationError() }
      })
    await model.watchWhileWelcomeOpen()
    #expect(log.all == Array(repeating: "status", count: 4))
  }
}

/// macOS asks before Ferry reaches the local network. Ferry says so the first time the user
/// reaches for Wi-Fi, never up front, and once only.
@MainActor
struct AppModelLocalNetworkNoteTests {
  private let log = CallLog()

  @Test func theFirstNetworkFormExplainsItOnce() async {
    let services = FakeServices(log: log)
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.refresh()
    #expect(!model.showsLocalNetworkNote)

    model.toggleNetworkForm(.address)
    #expect(model.showsLocalNetworkNote)
    #expect(services.marks.contains(.localNetworkExplained))

    model.dismissLocalNetworkNote()
    #expect(!model.showsLocalNetworkNote)

    let next = AppModel(client: FakeClient(log: log), services: services)
    await next.refresh()
    next.toggleNetworkForm(.code)
    #expect(!next.showsLocalNetworkNote)
  }

  /// Closing a form is not reaching for Wi-Fi.
  @Test func closingAFormDoesNotExplainIt() async {
    let services = FakeServices(log: log)
    services.marks = [.localNetworkExplained]
    let model = AppModel(client: FakeClient(log: log), services: services)
    model.toggleNetworkForm(.address)
    model.toggleNetworkForm(.address)
    #expect(!model.showsLocalNetworkNote)
  }

  @Test func useOverWiFiExplainsIt() async {
    let services = FakeServices(log: log)
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.useOverWiFi(DeviceID(serial: "P1"))
    #expect(model.showsLocalNetworkNote)
  }

  /// A remembered device was reached over the network before: macOS has asked already, and
  /// will not again. Recorded, not said.
  @Test func aMacThatReachedADeviceOverWiFiIsNotTold() async throws {
    let client = FakeClient(log: log)
    client.setStatus(
      [], adb: .available,
      remembered: [
        RememberedDevice(
          id: DeviceID(serial: "P1"), name: "Pixel 8",
          addresses: [try #require(WirelessEndpoint(parsing: "192.0.2.42:5555"))])
      ])
    let services = FakeServices(log: log)
    let model = AppModel(client: client, services: services)
    await model.refresh()
    model.toggleNetworkForm(.address)
    #expect(!model.showsLocalNetworkNote)
    #expect(services.marks.contains(.localNetworkExplained))
  }
}
