import Synchronization

/// Holds a fake's request until its caller cancels it, as `AgentClient` ends a cancelled
/// request, with no sleeping: each request held is announced on `arrivals`.
final class RequestPark: Sendable {
  /// A held request: waiting to be cancelled, or cancelled before it began to wait.
  private enum Held {
    case none
    case waiting(CheckedContinuation<Void, Never>)
    case cancelled
  }

  private let started = Mutex(false)
  private let held = Mutex(Held.none)
  let (arrivals, arrived) = AsyncStream<Void>.makeStream()

  var isOn: Bool { started.withLock { $0 } }

  func start() {
    started.withLock { $0 = true }
  }

  func waitUntilCancelled() async {
    arrived.yield()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let cancelled = held.withLock { held in
          if case .cancelled = held {
            held = .none
            return true
          }
          held = .waiting(continuation)
          return false
        }
        if cancelled { continuation.resume() }
      }
    } onCancel: {
      let waiting = held.withLock { held -> CheckedContinuation<Void, Never>? in
        if case .waiting(let continuation) = held {
          held = .none
          return continuation
        }
        held = .cancelled
        return nil
      }
      waiting?.resume()
    }
  }
}

/// Holds the next request that passes it until `release()`, with no sleeping: the request held
/// is announced on `arrivals` once it waits. Requests pass straight through unless `hold()` was
/// called first.
final class RequestGate: Sendable {
  private let holds = Mutex(false)
  private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
  let (arrivals, arrived) = AsyncStream<Void>.makeStream()

  func hold() {
    holds.withLock { $0 = true }
  }

  func passWhenReleased() async {
    let holding = holds.withLock { holds in
      defer { holds = false }
      return holds
    }
    guard holding else { return }
    await withCheckedContinuation { continuation in
      held.withLock { $0 = continuation }
      arrived.yield()
    }
  }

  func release() {
    held.withLock { held in
      held?.resume()
      held = nil
    }
  }
}
