import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryUI

@MainActor
struct AppModelTests {
  let log = CallLog()

  @Test func disabledProviderShowsTurnOnRow() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .disabled)
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.provider == .disabled)
    #expect(model.showsTurnOnRow)
    #expect(model.agent == .running)
    #expect(model.actionError == nil)
    model.turnOnInFinder()
    #expect(
      log.all.last
        == "open x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
  }

  /// Before any device has been ready there is no location to turn on, so the menu does not ask.
  @Test func noDomainsShowsNoTurnOnRow() async {
    let client = FakeClient(log: log)
    client.setStatus([], provider: .noDomains)
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.agent == .running)
    #expect(!model.showsTurnOnRow)
  }

  @Test func providerIsAssumedOnUntilTheAgentSaysOtherwise() {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    #expect(model.provider == .enabled)
    #expect(!model.showsTurnOnRow)
    #expect(model.agent == .checking)
  }

  @Test func notSharingFilesOpensGuideOnce() async {
    let client = FakeClient(log: log)
    client.setStatus([device("A1", model: "LinkRunner-100G", .notSharingFiles)])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.isGuidePresented)
    #expect(model.guideFamily == .netAllyAndroid8Board)
    #expect(model.takeGuideOpenRequest())
    #expect(!model.takeGuideOpenRequest())
    model.isGuidePresented = false
    await model.refresh()
    #expect(!model.isGuidePresented)
  }

  @Test func notSharingFilesWithUnknownModelOpensThePicker() async {
    let client = FakeClient(log: log)
    client.setStatus([device("P1", model: "Pixel 8", .notSharingFiles)])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.isGuidePresented)
    #expect(model.guideFamily == nil)
  }

  @Test func ejectingDoesNotOpenGuide() async {
    let client = FakeClient(log: log)
    let id = DeviceID(serial: "A1")
    client.setStatus([device("A1", model: "LinkRunner-100G", .ready([]))])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    client.setStatus([device("A1", model: "LinkRunner-100G", .ejected)])
    await model.eject(id)
    #expect(log.all.suffix(2) == ["eject A1", "status"])
    #expect(!model.isGuidePresented)
  }

  @Test func unreachableAgentIsNotNoDevice() async {
    let model = AppModel(client: UnreachableClient(), services: FakeServices(log: log))
    await model.refresh()
    #expect(model.agent == .unreachable)
    #expect(!model.showsTurnOnRow)
    model.considerEmptyGuide(openFor: .seconds(30))
    #expect(!model.isGuidePresented)
  }

  @Test func nothingDetectedForTenSecondsOpensGuideOnce() async {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.refresh()
    model.considerEmptyGuide(openFor: .seconds(8))
    #expect(!model.isGuidePresented)
    model.considerEmptyGuide(openFor: .seconds(10))
    #expect(model.isGuidePresented)
    #expect(model.guideFamily == nil)
    model.isGuidePresented = false
    model.considerEmptyGuide(openFor: .seconds(20))
    #expect(!model.isGuidePresented)
  }

  @Test func watchingRefreshesUntilCancelled() async {
    let sleeps = Mutex(0)
    let model = AppModel(
      client: FakeClient(log: log), services: FakeServices(log: log),
      sleep: { _ in
        let count = sleeps.withLock { count in
          count += 1
          return count
        }
        if count > 5 { throw CancellationError() }
      })
    await model.watchWhileMenuOpen()
    // Opening the menu reads the login item once, then the status every 2 s.
    #expect(log.all == ["readLoginItem"] + Array(repeating: "status", count: 6))
    #expect(model.isGuidePresented)
  }

  /// The 10 s before the guide opens count from the agent's first answer, not from the menu
  /// opening: until then Ferry does not know whether a device is attached.
  @Test func emptyGuideWaitsTenSecondsAfterTheFirstStatus() async {
    let polls = Mutex(0)
    let model = AppModel(
      client: StartingClient(failures: 5), services: FakeServices(log: log),
      sleep: { _ in
        let count = polls.withLock { count in
          count += 1
          return count
        }
        if count == 9 { throw CancellationError() }
      })
    await model.watchWhileMenuOpen()
    #expect(model.agent == .running)
    #expect(!model.isGuidePresented)
  }

  @Test func menuChecksUntilTheFirstStatus() async {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    #expect(model.isChecking)
    await model.refresh()
    #expect(!model.isChecking)
  }

  /// Refresh lists the ready devices' folders again on the agent, so changes made on a device
  /// reach Finder, then reads the status.
  @Test func refreshButtonRelistsReadyDevices() async {
    let client = FakeClient(log: log)
    client.setStatus([
      device("A1", model: "LinkRunner-100G", .ready([])),
      device("B1", model: "Pixel 8", .busy),
    ])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()

    await model.refreshDevices()

    #expect(log.all.suffix(2) == ["refresh A1", "status"])
  }

  /// Refresh asks the agent to try again every device it is not using: an ejected one is
  /// mounted again, one not sharing files is checked again. The agent says which is which, so
  /// this holds after the app relaunches.
  @Test func refreshMountsEjectedAndRechecksNotSharingDevices() async {
    let client = FakeClient(log: log)
    client.setStatus([
      device("A1", model: "LinkRunner-100G", .ejected),
      device("B1", model: "Pixel 8", .notSharingFiles),
      device("C1", model: "Pixel 9", .busy),
    ])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()

    await model.refreshDevices()
    #expect(log.all.suffix(3) == ["recheck A1", "recheck B1", "status"])
  }

  @Test func mountSendsRecheck() async {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.mount(DeviceID(serial: "A1"))
    #expect(log.all.suffix(2) == ["recheck A1", "status"])
  }

  /// SMAppService must not run on the main thread: the model touches no system service when it
  /// is made, and reads the login item only once launched, off the main actor.
  @Test func makingTheModelTouchesNoSystemService() {
    _ = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    #expect(log.all.isEmpty)
  }

  @Test func launchRegistersTheAgentThenReadsStatusAndLoginItem() async {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.launch()
    #expect(log.all == ["registerAgent", "status", "readLoginItem"])
    #expect(model.opensAtLogin)
  }

  @Test func deviceTextIsEscaped() async {
    let shown = device("A1", model: "Evil\u{1B}[2J\u{202E}", .busy)
    let client = FakeClient(log: log)
    client.setStatus([shown])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.displayName(of: shown) == "Evil\\u{1B}[2J\\u{202E}")
  }

  /// Two units of one model whose serials end alike are told apart as their Finder locations
  /// are: by as much of the serial as it takes.
  @Test func sameNamedDevicesAreToldApartAsInFinder() async {
    let first = device("0123456789abcdef", model: "LinkRunner-100G", .busy)
    let second = device("0b23456789abcdef", model: "LinkRunner-100G", .busy)
    let other = device("ZZZZ", model: "Phone", .busy)
    let client = FakeClient(log: log)
    client.setStatus([first, second, other])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.displayName(of: first) == "LinkRunner-100G (123456789abcdef)")
    #expect(model.displayName(of: second) == "LinkRunner-100G (b23456789abcdef)")
    #expect(model.displayName(of: other) == "Phone")
  }

  /// The developer windows name the device as the menu does, so two units of one model have two
  /// titles; the title is one format a language can reorder.
  @Test func developerWindowsAreNamedAsTheMenuNamesTheDevice() async {
    let first = device("0123456789abcdef", model: "LinkRunner-100G", .busy)
    let second = device("0b23456789abcdef", model: "LinkRunner-100G", .busy)
    let client = FakeClient(log: log)
    client.setStatus([first, second])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    let titles = [first, second].map {
      DevicePresentation.logTitle(name: model.windowName(of: $0.id))
    }
    #expect(
      titles == [
        "Logcat · LinkRunner-100G (123456789abcdef)", "Logcat · LinkRunner-100G (b23456789abcdef)",
      ])
    #expect(model.fileName(of: second.id) == "LinkRunner-100G (b23456789abcdef)")
    #expect(DevicePresentation.logTitle(name: "") == "Logcat")
  }
}
