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
  private let discardResult = Mutex<AgentResponse>(.done)
  private let sendResult = Mutex<AgentResponse>(.done)
  /// Set by `parkInstalls()`: an install waits until its caller cancels it, then throws
  /// `.cancelled` as `AgentClient` does.
  private let installsParked = Mutex(false)
  /// What the agent writes into the file a capture request carries.
  private let toolBytes = Mutex(Data())
  /// Progress the agent reports on a tool request before it answers.
  private let toolProgress = Mutex<[(UInt64, UInt64)]>([])
  /// The log stream: the client's handler for lines, how the stream ends if it ends by itself,
  /// and the request waiting for a stop.
  private let logHandler = Mutex<LogBatchHandler?>(nil)
  private let streamEnd = Mutex<AgentResponse?>(nil)
  private let streamWaiter = Mutex<CheckedContinuation<AgentResponse, Never>?>(nil)
  /// What the developer tools answer.
  let forwardList = Mutex<[PortForward]>([])
  let infoReply = Mutex<AgentResponse>(.toolFailed(.notOverADB))
  let shellReply = Mutex<AgentResponse>(.toolFailed(.adbNotFound))
  let forwardReply = Mutex<AgentResponse>(.done)

  init(log: CallLog) {
    self.log = log
  }

  func setStatus(
    _ devices: [AttachedDevice], provider: ProviderState = .enabled,
    transfers: [ActiveTransfer] = [], adb: ADBStatus? = nil,
    awaitingUSBDebugging: [DeviceID] = [], awaitingAuthorization: [String] = [],
    remembered: [RememberedDevice] = [], unconfirmed: [UnconfirmedAddress] = [],
    recordings: [ActiveRecording] = [], usbWatchFailed: Bool = false,
    sessions: [DeviceID: UInt64] = [:], connectedAddresses: [DeviceID: WirelessEndpoint] = [:]
  ) {
    status.withLock {
      $0 = .status(
        StatusReport(
          devices: devices, provider: provider, transfers: transfers,
          awaitingAuthorization: awaitingAuthorization, adbStatus: adb,
          awaitingUSBDebugging: awaitingUSBDebugging,
          remembered: remembered, unconfirmed: unconfirmed, recordings: recordings,
          usbWatchFailed: usbWatchFailed, sessions: sessions,
          connectedAddresses: connectedAddresses))
    }
  }

  /// What the agent answers to `.status` now, to set back with `restoreStatus`.
  var statusReply: AgentResponse { status.withLock { $0 } }

  func restoreStatus(_ reply: AgentResponse) {
    status.withLock { $0 = reply }
  }

  /// What the agent answers to the next tool request, after reporting `progress`.
  func setTool(
    _ response: AgentResponse, progress: [(UInt64, UInt64)] = [], writes bytes: Data = Data()
  ) {
    toolResult.withLock { $0 = response }
    toolProgress.withLock { $0 = progress }
    toolBytes.withLock { $0 = bytes }
  }

  func parkInstalls() {
    installsParked.withLock { $0 = true }
  }

  /// What the agent answers to a file sent to a device.
  func setSend(_ response: AgentResponse) {
    sendResult.withLock { $0 = response }
  }

  /// What the agent answers to Discard.
  func setDiscard(_ response: AgentResponse) {
    discardResult.withLock { $0 = response }
  }

  private func clearRecordings() {
    status.withLock { reply in
      guard case .status(let report) = reply else { return }
      reply = .status(
        StatusReport(
          devices: report.devices, provider: report.provider, transfers: report.transfers,
          adbStatus: report.adbStatus, remembered: report.remembered))
    }
  }

  private func tool(_ progress: TransferProgressHandler?, into file: FileHandle? = nil)
    -> AgentResponse
  {
    for (done, total) in toolProgress.withLock({ $0 }) { progress?(done, total) }
    if let file { try? file.write(contentsOf: toolBytes.withLock { $0 }) }
    return toolResult.withLock { $0 }
  }

  /// Sends lines to the log window, as the agent's batches do.
  func push(_ batch: LogBatch) async {
    let handler = logHandler.withLock { $0 }
    await handler?(batch)
  }

  /// The log stream ends by itself with `response`, as when the device ends it or is lost.
  func endStream(with response: AgentResponse) {
    if let waiter = streamWaiter.withLock({ state -> CheckedContinuation<AgentResponse, Never>? in
      defer { state = nil }
      return state
    }) {
      waiter.resume(returning: response)
    } else {
      streamEnd.withLock { $0 = response }
    }
  }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?,
    logs: LogBatchHandler?
  ) async throws(TransportError) -> AgentResponse {
    guard case .startLogcat(let id, _) = request else {
      return try await send(request, file: file, progress: progress)
    }
    logHandler.withLock { $0 = logs }
    log.record("startLogcat \(id.serial)")
    if let ended = streamEnd.withLock({ $0 }) { return ended }
    return await withCheckedContinuation { continuation in
      streamWaiter.withLock { $0 = continuation }
    }
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
    if case .installAPK(let id, let name) = request, installsParked.withLock({ $0 }) {
      log.record("installAPK \(id.serial) \(name) parked")
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
      log.record("installAPK cancelled")
      throw .cancelled
    }
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
      let reply = tool(progress, into: file)
      // Collected: the agent no longer lists it.
      if reply == .done { clearRecordings() }
      return reply
    case .startRecording(let id):
      log.record("startRecording \(id.serial)")
      return tool(progress)
    case .stopRecording(let id):
      log.record("stopRecording \(id.serial)")
      return .done
    case .sendFile(let id, let name):
      log.record("sendFile \(id.serial) \(name) file:\(file != nil)")
      return sendResult.withLock { $0 }
    case .discardRecording(let id):
      log.record("discardRecording \(id.serial)")
      let reply = discardResult.withLock { $0 }
      if reply == .done { clearRecordings() }
      return reply
    default:
      return developerReply(request)
    }
  }

  private func developerReply(_ request: AgentRequest) -> AgentResponse {
    switch request {
    case .stopLogcat(let id, _):
      log.record("stopLogcat \(id.serial)")
      endStream(with: .done)
      return .done
    case .forwards(let id):
      log.record("forwards \(id.serial)")
      return .forwards(forwardList.withLock { $0 })
    case .addForward(let id, let forward):
      log.record("addForward \(id.serial) \(forward.local) \(forward.remote)")
      let reply = forwardReply.withLock { $0 }
      if reply == .done { forwardList.withLock { $0.append(forward) } }
      return reply
    case .removeForward(let id, let local):
      log.record("removeForward \(id.serial) \(local)")
      forwardList.withLock { $0.removeAll { $0.local == local } }
      return forwardReply.withLock { $0 }
    case .deviceInfo(let id):
      log.record("deviceInfo \(id.serial)")
      return infoReply.withLock { $0 }
    case .shellTarget(let id):
      log.record("shellTarget \(id.serial)")
      return shellReply.withLock { $0 }
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

/// `inner`, but each device-info request waits until `release()` or until its task is
/// cancelled, which it records and answers with `.cancelled` as `AgentClient` does. Each status
/// request first runs `onStatus`.
final class HeldInfoClient: AgentSending {
  let inner: FakeClient
  let onStatus = Mutex<(@Sendable () -> Void)?>(nil)
  /// Set when a reply is already on its way: cancelling the request no longer stops it.
  let ignoresCancellation = Atomic(false)
  private let arrived: AsyncStream<Void>
  private let arrivals: AsyncStream<Void>.Continuation
  private let held = Mutex([Int: CheckedContinuation<Void, Never>]())
  private let nextRequest = Atomic(0)

  init(_ inner: FakeClient) {
    self.inner = inner
    (arrived, arrivals) = AsyncStream.makeStream()
  }

  /// Returns once a device-info request is waiting.
  func arrival() async {
    for await _ in arrived { return }
  }

  /// Lets every waiting device-info request through.
  func release() {
    let waiting = held.withLock { held in
      defer { held = [:] }
      return held.values
    }
    for continuation in waiting { continuation.resume() }
  }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError) -> AgentResponse {
    if case .status = request { onStatus.withLock { $0 }?() }
    guard case .deviceInfo(let id) = request else {
      return try await inner.send(request, file: file, progress: progress)
    }
    let number = nextRequest.add(1, ordering: .relaxed).oldValue
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        held.withLock { $0[number] = continuation }
        arrivals.yield()
        if Task.isCancelled { held.withLock { $0.removeValue(forKey: number) }?.resume() }
      }
    } onCancel: {
      guard !ignoresCancellation.load(ordering: .relaxed) else { return }
      held.withLock { $0.removeValue(forKey: number) }?.resume()
    }
    if Task.isCancelled, !ignoresCancellation.load(ordering: .relaxed) {
      inner.log.record("deviceInfo \(id.serial) cancelled")
      throw .cancelled
    }
    return try await inner.send(request, file: file, progress: progress)
  }
}
