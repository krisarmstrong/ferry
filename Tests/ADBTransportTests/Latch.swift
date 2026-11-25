import Foundation
import os

/// Something a fake server sees happen once, such as its client hanging up. `wait()` returns once
/// it has, with no deadline but the test's time limit: the test waits on the event itself rather
/// than polling against a guess at how long a loaded machine takes.
final class Latch: Sendable {
  private struct State {
    var fired = false
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var fired: Bool { state.withLock { $0.fired } }

  func fire() {
    let waiters = state.withLock { state in
      state.fired = true
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Returns once `fire()` has run, or the caller is cancelled, as by a time limit.
  func wait() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let fired = state.withLock { state in
          guard !state.fired, !Task.isCancelled else { return true }
          state.waiters[id] = continuation
          return false
        }
        if fired { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
    }
  }
}
