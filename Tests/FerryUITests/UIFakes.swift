import DeviceKit
import FerryIPC
import Foundation
import Synchronization

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
  private let wirelessResult = Mutex<AgentResponse>(.wireless(.connected))
  private let toolResult = Mutex<AgentResponse>(.done)
  /// What the agent writes into the file a capture request carries.
  private let toolBytes = Mutex(Data())
  /// Progress the agent reports on a tool request before it answers.
  private let toolProgress = Mutex<[(UInt64, UInt64)]>([])

  init(log: CallLog) {
    self.log = log
  }

  func setStatus(
    _ devices: [AttachedDevice], provider: ProviderState = .enabled,
    transfers: [ActiveTransfer] = [], preserved: [URL] = [], adb: ADBStatus? = nil,
    awaitingUSBDebugging: [DeviceID] = [], awaitingAuthorization: [String] = [],
    remembered: [RememberedDevice] = [], unconfirmed: [UnconfirmedAddress] = [],
    recordings: [ActiveRecording] = []
  ) {
    status.withLock {
      $0 = .status(
        StatusReport(
          devices: devices, provider: provider, transfers: transfers,
          awaitingAuthorization: awaitingAuthorization, adbStatus: adb,
          awaitingUSBDebugging: awaitingUSBDebugging, preservedChanges: preserved,
          remembered: remembered, unconfirmed: unconfirmed, recordings: recordings))
    }
  }

  /// What the agent answers to the next tool request, after reporting `progress`.
  func setTool(
    _ response: AgentResponse, progress: [(UInt64, UInt64)] = [], writes bytes: Data = Data()
  ) {
    toolResult.withLock { $0 = response }
    toolProgress.withLock { $0 = progress }
    toolBytes.withLock { $0 = bytes }
  }

  private func tool(_ progress: TransferProgressHandler?, into file: FileHandle? = nil)
    -> AgentResponse
  {
    for (done, total) in toolProgress.withLock({ $0 }) { progress?(done, total) }
    if let file { try? file.write(contentsOf: toolBytes.withLock { $0 }) }
    return toolResult.withLock { $0 }
  }

  /// What the agent answers to the next wireless request.
  func setWireless(_ response: AgentResponse) {
    wirelessResult.withLock { $0 = response }
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
    case .recheckADB:
      log.record("recheckADB")
      return .done
    case .removeAllDomains:
      log.record("removeAllDomains")
      return removeResult.withLock { $0 }
    case .connectAddress(let address):
      log.record("connectAddress \(address.argument)")
      return wirelessResult.withLock { $0 }
    case .pair(let address, _):
      log.record("pair \(address.argument)")
      return wirelessResult.withLock { $0 }
    case .enableWireless(let id):
      log.record("enableWireless \(id.serial)")
      return wirelessResult.withLock { $0 }
    case .connectWireless(let id):
      log.record("connectWireless \(id.serial)")
      return wirelessResult.withLock { $0 }
    case .forgetWireless(let id):
      log.record("forgetWireless \(id.serial)")
      return .done
    case .confirmWireless(let offer):
      log.record("confirmWireless \(offer.address.argument) \(offer.id.serial) \(offer.name)")
      return wirelessResult.withLock { $0 }
    case .ignoreWireless(let address):
      log.record("ignoreWireless \(address.argument)")
      return .done
    default:
      return toolReply(request, file: file, progress: progress)
    }
  }

  private func toolReply(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) -> AgentResponse {
    switch request {
    case .installAPK(let id, let name):
      log.record("installAPK \(id.serial) \(name) file:\(file != nil)")
      return tool(progress)
    case .screenshot(let id):
      log.record("screenshot \(id.serial) file:\(file != nil)")
      return tool(progress, into: file)
    case .saveRecording(let id):
      log.record("saveRecording \(id.serial) file:\(file != nil)")
      // Collected: the agent no longer lists it.
      status.withLock { reply in
        guard case .status(let report) = reply else { return }
        reply = .status(
          StatusReport(
            devices: report.devices, provider: report.provider, transfers: report.transfers,
            adbStatus: report.adbStatus, remembered: report.remembered))
      }
      return tool(progress, into: file)
    case .startRecording(let id):
      log.record("startRecording \(id.serial)")
      return tool(progress)
    case .stopRecording(let id):
      log.record("stopRecording \(id.serial)")
      return .done
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

  func copy(_ text: String) {
    log.record("copy \(text)")
  }

  /// What the open panel returns: `nil` is Cancel.
  var pickedAPK: URL?
  /// Where captures go.
  var folders: [URL] = []

  func captureFolders() -> [URL] { folders }

  func chooseAPK() async -> URL? {
    log.record("chooseAPK")
    return pickedAPK
  }
}

func device(
  _ serial: String, model: String, _ state: DeviceState,
  method: ConnectionMethod = .usbFileTransfer
) -> AttachedDevice {
  AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: serial), manufacturer: "NetAlly", model: model),
    state: state, method: method)
}
