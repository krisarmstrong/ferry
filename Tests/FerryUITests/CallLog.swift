import Foundation
import Synchronization

/// The calls the fakes saw, in order, shared between the client and the services.
final class CallLog: Sendable {
  private struct State {
    var calls: [String] = []
    var waiters: [UUID: (call: String, continuation: CheckedContinuation<Void, Never>)] = [:]
  }

  private let state = Mutex(State())

  func record(_ call: String) {
    let due = state.withLock { state in
      state.calls.append(call)
      let due = state.waiters.filter { $0.value.call == call }
      for id in due.keys { state.waiters[id] = nil }
      return due.values.map(\.continuation)
    }
    for waiter in due { waiter.resume() }
  }

  var all: [String] { state.withLock { $0.calls } }

  /// Returns once `call` has been recorded, or the caller is cancelled (a test's time limit).
  func waitFor(_ call: String) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let ready = state.withLock { state in
          guard !state.calls.contains(call), !Task.isCancelled else { return true }
          state.waiters[id] = (call, continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
    }
  }
}
