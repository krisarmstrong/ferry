import DeviceKit
import FerryIPC
import Foundation
import Synchronization

/// The devices the agent last reported, for a menu Finder asks for synchronously.
///
/// Finder waits on the extension for its menu, so the list asks the agent and waits a moment for
/// the answer: a device plugged in just before the right-click shows up. An agent that takes
/// longer leaves the last answer, and the request keeps running to update it for the next menu.
public final class DeviceList: Sendable {
  private let agent: any AgentSending
  private struct State {
    var devices: [AttachedDevice] = []
    /// The number of the last request made, and of the one that gave `devices`.
    var request: UInt64 = 0
    var answered: UInt64 = 0
  }

  private let state = Mutex(State())

  public init(agent: any AgentSending) {
    self.agent = agent
  }

  /// Asks the agent and stores its answer, unless a later request has answered first. An agent
  /// that cannot be reached has no devices.
  public func refresh() async {
    let request = state.withLock { state in
      state.request += 1
      return state.request
    }
    let answer: [AttachedDevice]
    do {
      if case .status(let report) = try await agent.send(.status, file: nil) {
        answer = report.devices
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
    }
  }

  /// Refreshes, and returns the answer if it comes within `limit`, else the last one. Blocks the
  /// calling thread for at most `limit`.
  public func fresh(waitingUpTo limit: Duration) -> [AttachedDevice] {
    let answered = DispatchSemaphore(value: 0)
    Task {
      await refresh()
      answered.signal()
    }
    let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    _ = answered.wait(timeout: .now() + seconds)
    return state.withLock { $0.devices }
  }
}
