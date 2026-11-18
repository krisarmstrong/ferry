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
private final class FakeClient: AgentSending {
  let log: CallLog
  private let status = Mutex<AgentResponse>(.status(devices: [], providerEnabled: true))
  private let removeResult = Mutex<AgentResponse>(.removed(preserved: []))
  private let ejectResult = Mutex<AgentResponse>(.removed(preserved: []))

  init(log: CallLog) {
    self.log = log
  }

  func setStatus(_ devices: [AttachedDevice], providerEnabled: Bool = true) {
    status.withLock { $0 = .status(devices: devices, providerEnabled: providerEnabled) }
  }

  func failRemoveAll() {
    removeResult.withLock { $0 = .failure(.deviceDisconnected) }
  }

  /// The agent kept unsent changes of the removed domains in `preserved`.
  func preserve(_ preserved: [URL]) {
    removeResult.withLock { $0 = .removed(preserved: preserved) }
    ejectResult.withLock { $0 = .removed(preserved: preserved) }
  }

  func send(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
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
private final class StartingClient: AgentSending {
  private let remaining: Mutex<Int>

  init(failures: Int) {
    remaining = Mutex(failures)
  }

  func send(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
    -> AgentResponse
  {
    let failing = remaining.withLock { count in
      defer { count -= 1 }
      return count > 0
    }
    if failing { throw .deviceDisconnected }
    return .status(devices: [], providerEnabled: true)
  }
}

/// Refuses every request, as a client whose agent is not running does.
private struct UnreachableClient: AgentSending {
  func send(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
    -> AgentResponse
  {
    throw .deviceDisconnected
  }
}

@MainActor
private final class FakeServices: SystemServicing {
  let log: CallLog
  var opensAtLogin = true
  var failLoginItem = false

  init(log: CallLog) {
    self.log = log
  }

  func setOpensAtLogin(_ enabled: Bool) throws {
    log.record("opensAtLogin \(enabled)")
    if failLoginItem { throw CocoaError(.featureUnsupported) }
    opensAtLogin = enabled
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

private func device(_ serial: String, model: String, _ state: DeviceState) -> AttachedDevice {
  AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: serial), manufacturer: "NetAlly", model: model),
    state: state)
}

@MainActor
struct AppModelTests {
  let log = CallLog()

  @Test func disabledProviderShowsTurnOnRow() async {
    let client = FakeClient(log: log)
    client.setStatus([], providerEnabled: false)
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    #expect(model.providerEnabled == false)
    #expect(model.showsTurnOnRow)
    #expect(model.agent == .running)
    #expect(model.actionError == nil)
    model.turnOnInFinder()
    #expect(
      log.all.last
        == "open x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
  }

  @Test func providerIsAssumedOnUntilTheAgentSaysOtherwise() {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    #expect(model.providerEnabled)
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
    client.setStatus([device("A1", model: "LinkRunner-100G", .notSharingFiles)])
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

  @Test func removeFerryCallsRemoveAllThenUnregister() async {
    let services = FakeServices(log: log)
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.removeFerry()
    #expect(log.all == ["removeAllDomains", "unregisterAgent", "opensAtLogin false", "quit"])
  }

  @Test func removeFerryQuitsWhenOnlyTheLoginItemRemains() async {
    let services = FakeServices(log: log)
    services.failLoginItem = true
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.removeFerry()
    #expect(log.all == ["removeAllDomains", "unregisterAgent", "opensAtLogin false", "quit"])
  }

  @Test func removeFerryStopsWhenDomainsRemain() async {
    let client = FakeClient(log: log)
    client.failRemoveAll()
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.removeFerry()
    #expect(log.all == ["removeAllDomains"])
    #expect(model.actionError != nil)
  }

  static let preserved = URL(
    filePath: "/Users/me/Library/Unsent Ferry Changes", directoryHint: .isDirectory)

  @Test func ejectShowsWhereUnsentChangesWereSaved() async {
    let client = FakeClient(log: log)
    client.preserve([Self.preserved])
    let model = AppModel(client: client, services: FakeServices(log: log))

    await model.eject(DeviceID(serial: "A1"))

    #expect(model.preservedChanges == [Self.preserved])
    #expect(model.actionError == nil)
    model.revealPreservedChanges()
    #expect(log.all.last == "reveal \(Self.preserved.path)")
  }

  @Test func ejectWithNothingUnsentShowsNoMessage() async {
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.eject(DeviceID(serial: "A1"))
    #expect(model.preservedChanges.isEmpty)
  }

  /// Ferry quits right after Remove Ferry, so a menu message would never be seen: the saved
  /// changes are shown in Finder instead.
  @Test func removeFerryRevealsSavedChangesBeforeQuitting() async {
    let client = FakeClient(log: log)
    client.preserve([Self.preserved])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.removeFerry()
    #expect(
      log.all == [
        "removeAllDomains", "unregisterAgent", "reveal \(Self.preserved.path)",
        "opensAtLogin false", "quit",
      ])
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

  @Test func deviceTextIsEscaped() {
    let shown = device("A1", model: "Evil\u{1B}[2J\u{202E}", .busy)
    #expect(shown.displayName == "Evil\\u{1B}[2J\\u{202E}")
  }
}
