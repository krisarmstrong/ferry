import Foundation

/// Waiting for the device to finish with its connections, on the event rather than a deadline.
extension FakeAndroid {
  /// What a test can wait for the device to have no more of.
  enum Open: Sendable {
    /// `sync:` connections.
    case syncs
    /// Connections `serve(serial:)` is serving, any clean-up such as unlinking a broken upload
    /// included.
    case connections
  }

  /// Returns once the device has none of `kind` open, or the caller is cancelled, as by a time
  /// limit. A connection the client went on to use past its handshake was open by then.
  func waitUntilNone(_ kind: Open) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let reached = state.withLock { state in
          guard state.count(kind) > 0, !Task.isCancelled else { return true }
          state.quietWaiters[id] = (kind, continuation)
          return false
        }
        if reached { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.quietWaiters.removeValue(forKey: id) }?.continuation.resume()
    }
  }

  func opened(_ kind: Open) {
    state.withLock { $0.adjust(kind, by: 1) }
  }

  /// Counts one of `kind` closed, waking whoever waits for none to be open.
  func closed(_ kind: Open) {
    let due = state.withLock { state in
      state.adjust(kind, by: -1)
      guard state.count(kind) == 0 else { return [CheckedContinuation<Void, Never>]() }
      let due = state.quietWaiters.filter { $0.value.kind == kind }
      for id in due.keys { state.quietWaiters[id] = nil }
      return due.values.map(\.continuation)
    }
    for waiter in due { waiter.resume() }
  }
}

extension FakeAndroid.State {
  func count(_ kind: FakeAndroid.Open) -> Int {
    switch kind {
    case .syncs: openSyncs
    case .connections: serving
    }
  }

  mutating func adjust(_ kind: FakeAndroid.Open, by change: Int) {
    switch kind {
    case .syncs: openSyncs += change
    case .connections: serving += change
    }
  }
}
