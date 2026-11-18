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
  private let removeResult = Mutex<AgentResponse>(.done)

  init(log: CallLog) {
    self.log = log
  }

  func setStatus(_ devices: [AttachedDevice], providerEnabled: Bool = true) {
    status.withLock { $0 = .status(devices: devices, providerEnabled: providerEnabled) }
  }

  func failRemoveAll() {
    removeResult.withLock { $0 = .failure(.deviceDisconnected) }
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
      return .done
    case .recheck(let id):
      log.record("recheck \(id.serial)")
      return .done
    case .removeAllDomains:
      log.record("removeAllDomains")
      return removeResult.withLock { $0 }
    default:
      return .failure(.unsupported("\(request)"))
    }
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

  init(log: CallLog) {
    self.log = log
  }

  func setOpensAtLogin(_ enabled: Bool) throws {
    log.record("opensAtLogin \(enabled)")
    opensAtLogin = enabled
  }

  func unregisterAgent() async throws {
    log.record("unregisterAgent")
  }

  func open(_ url: URL) {
    log.record("open \(url.absoluteString)")
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

  @Test func removeFerryCallsRemoveAllThenUnregister() async {
    let services = FakeServices(log: log)
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

  @Test func deviceTextIsEscaped() {
    let shown = device("A1", model: "Evil\u{1B}[2J\u{202E}", .busy)
    #expect(shown.displayName == "Evil\\u{1B}[2J\\u{202E}")
  }
}
