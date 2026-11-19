import DeviceKit
import FerryIPC
import Foundation
import Synchronization

/// The devices the agent last reported, for a menu Finder asks for synchronously.
///
/// Finder waits on the extension for its menu, so the list asks the agent and waits a moment for
/// the answer: a device plugged in just before the right-click shows up. An agent that takes
/// longer leaves the last answer, and its request keeps running to update it for the next menu.
/// While a request is running no other is made, so an agent that never answers holds one
/// request, not one per menu.
public final class DeviceList: Sendable {
  private struct State {
    var devices: [DeviceSummary] = []
    /// The number of the last request made, and of the one that gave `devices`.
    var request: UInt64 = 0
    var answered: UInt64 = 0
    /// Menus waiting for the next answer.
    var waiters: [ObjectIdentifier: DispatchSemaphore] = [:]

    var inFlight: Bool { request > answered }
  }

  private let agent: any AgentSending
  private let state = Mutex(State())

  public init(agent: any AgentSending) {
    self.agent = agent
  }

  /// The last answer.
  public var current: [DeviceSummary] {
    state.withLock { $0.devices }
  }

  /// How many requests the list has made, for tests: `fresh` decides under the lock.
  var requestsMade: UInt64 {
    state.withLock { $0.request }
  }

  /// Asks the agent and stores its answer, unless a later request has answered first. An agent
  /// that cannot be reached has no devices.
  public func refresh() async {
    let request = state.withLock { state in
      state.request += 1
      return state.request
    }
    await ask(request)
  }

  /// Returns the agent's answer if it comes within `limit`, else the last one, asking the agent
  /// unless a request is already running. Blocks the calling thread for at most `limit`.
  public func fresh(waitingUpTo limit: Duration) -> [DeviceSummary] {
    let answered = DispatchSemaphore(value: 0)
    let key = ObjectIdentifier(answered)
    let request = state.withLock { state -> UInt64? in
      state.waiters[key] = answered
      guard !state.inFlight else { return nil }
      state.request += 1
      return state.request
    }
    if let request {
      Task { await ask(request) }
    }
    let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    _ = answered.wait(timeout: .now() + seconds)
    return state.withLock { state in
      state.waiters[key] = nil
      return state.devices
    }
  }

  private func ask(_ request: UInt64) async {
    let answer: [DeviceSummary]
    do {
      if case .devices(let devices) = try await agent.send(.devices, file: nil) {
        answer = devices
      } else {
        answer = []
      }
    } catch {
      answer = []
    }
    state.withLock { state in
      guard request > state.answered else { return }
      state.devices = answer
      state.answered = request
      for waiter in state.waiters.values { waiter.signal() }
      state.waiters = [:]
    }
  }
}
