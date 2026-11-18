import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryUI

/// The calls the fakes saw, in order, shared between the client and the services.
final class CallLog: Sendable {
  private let calls = Mutex<[String]>([])

  func record(_ call: String) {
    calls.withLock { $0.append(call) }
  }

  var all: [String] { calls.withLock { $0 } }
}

/// Answers `.status` with whatever the test last set, and records every request.
final class FakeClient: AgentSending {
  let log: CallLog
  private let status = Mutex<AgentResponse>(.status(StatusReport(devices: [], provider: .enabled)))
  private let removeResult = Mutex<AgentResponse>(.removed(preserved: []))
  private let ejectResult = Mutex<AgentResponse>(.removed(preserved: []))

  init(log: CallLog) {
    self.log = log
  }

  func setStatus(
    _ devices: [AttachedDevice], provider: ProviderState = .enabled,
    transfers: [ActiveTransfer] = []
  ) {
    status.withLock {
      $0 = .status(StatusReport(devices: devices, provider: provider, transfers: transfers))
    }
  }

  func failRemoveAll() {
    removeResult.withLock { $0 = .failure(.deviceDisconnected) }
  }

  /// The agent kept unsent changes of the removed domains in `preserved`.
  func preserve(_ preserved: [URL]) {
    removeResult.withLock { $0 = .removed(preserved: preserved) }
    ejectResult.withLock { $0 = .removed(preserved: preserved) }
  }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError)
    -> AgentResponse
  {
    switch request {
    case .status:
      log.record("status")
      return status.withLock { $0 }
    case .eject(let id):
      log.record("eject \(id.serial)")
      return ejectResult.withLock { $0 }
    case .recheck(let id):
      log.record("recheck \(id.serial)")
      return .done
    case .refresh(let id):
      log.record("refresh \(id.serial)")
      return .done
    case .removeAllDomains:
      log.record("removeAllDomains")
      return removeResult.withLock { $0 }
    default:
      return .failure(.unsupported("\(request)"))
    }
  }
}

/// Fails the first `failures` status requests, as a client whose agent is still starting does,
/// then answers with no devices.
final class StartingClient: AgentSending {
  private let remaining: Mutex<Int>

  init(failures: Int) {
    remaining = Mutex(failures)
  }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError)
    -> AgentResponse
  {
    let failing = remaining.withLock { count in
      defer { count -= 1 }
      return count > 0
    }
    if failing { throw .deviceDisconnected }
    return .status(StatusReport(devices: [], provider: .enabled))
  }
}

/// Refuses every request, as a client whose agent is not running does.
struct UnreachableClient: AgentSending {
  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError)
    -> AgentResponse
  {
    throw .deviceDisconnected
  }
}

@MainActor
final class FakeServices: SystemServicing {
  let log: CallLog
  var loginItem = true
  var failLoginItem = false
  var helper = HelperStatus.allowed

  init(log: CallLog) {
    self.log = log
  }

  func registerAgent() async {
    log.record("registerAgent")
  }

  func helperStatus() async -> HelperStatus {
    helper
  }

  func opensAtLogin() async -> Bool {
    log.record("readLoginItem")
    return loginItem
  }

  func setOpensAtLogin(_ enabled: Bool) async throws {
    log.record("opensAtLogin \(enabled)")
    if failLoginItem { throw CocoaError(.featureUnsupported) }
    loginItem = enabled
  }

  func unregisterAgent() async throws {
    log.record("unregisterAgent")
  }

  func open(_ url: URL) {
    log.record("open \(url.absoluteString)")
  }

  func reveal(_ urls: [URL]) {
    log.record("reveal \(urls.map(\.path).joined(separator: ","))")
  }

  func quit() {
    log.record("quit")
  }
}

func device(_ serial: String, model: String, _ state: DeviceState) -> AttachedDevice {
  AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: serial), manufacturer: "NetAlly", model: model),
    state: state)
}

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
    #expect(log.all == Array(repeating: "status", count: 6))
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

  @Test func deviceTextIsEscaped() {
    let shown = device("A1", model: "Evil\u{1B}[2J\u{202E}", .busy)
    #expect(shown.displayName == "Evil\\u{1B}[2J\\u{202E}")
  }
}
