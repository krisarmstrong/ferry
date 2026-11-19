import DeviceKit
import Synchronization

/// A fake device's folder watches: each `watch` call is recorded, and a test sends hints on the
/// latest one or ends it, as a device's watcher would.
public final class FakeWatches: Sendable {
  private struct State {
    var requests: [[FolderHint]] = []
    var current: AsyncStream<FolderHint>.Continuation?
    var supported = true
    /// Counts the watches started, so a watch stopped late cannot clear a newer one.
    var generation = 0
    var waiters: [Int: Waiter] = [:]
    var nextWaiter = 0
  }

  private struct Waiter {
    let ready: @Sendable ([[FolderHint]]) -> Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private let state = Mutex(State())

  public init() {}

  /// The folders of every watch started, oldest first.
  public var requests: [[FolderHint]] { state.withLock { $0.requests } }

  /// Whether a watch is running: started, and neither ended nor stopped by its caller.
  public var isWatching: Bool { state.withLock { $0.current != nil } }

  /// Whether the device can watch at all; one that cannot answers `nil`.
  public func setSupported(_ supported: Bool) {
    state.withLock { $0.supported = supported }
  }

  /// Sends `hint` on the running watch.
  public func send(_ hint: FolderHint) {
    _ = state.withLock { $0.current }?.yield(hint)
  }

  /// Ends the running watch, as a device's watcher that exits.
  public func end() {
    state.withLock { $0.current }?.finish()
  }

  /// Returns once `count` watches have been started, or the calling task is cancelled.
  public func waitForRequests(_ count: Int) async {
    await waitUntil { $0.count >= count }
  }

  /// Returns once the watches started so far satisfy `ready`, or the calling task is cancelled.
  public func waitUntil(_ ready: @escaping @Sendable ([[FolderHint]]) -> Bool) async {
    let id = state.withLock { state in
      state.nextWaiter += 1
      return state.nextWaiter
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let ready = state.withLock { state in
          guard !ready(state.requests), !Task.isCancelled else { return true }
          state.waiters[id] = Waiter(ready: ready, continuation: continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      state.withLock { state in
        state.waiters.removeValue(forKey: id)?.continuation
      }?.resume()
    }
  }

  /// A watch just started: its generation, the waits it satisfies, and the watch it replaced.
  private struct Started {
    let generation: Int
    let ready: [Int: Waiter]
    let replaced: AsyncStream<FolderHint>.Continuation?
  }

  func start(_ folders: [FolderHint]) -> AsyncStream<FolderHint>? {
    let (stream, continuation) = AsyncStream.makeStream(of: FolderHint.self)
    // The replaced watch is ended outside the lock: ending it runs its `stopped`.
    let started = state.withLock { state -> Started? in
      guard state.supported else { return nil }
      let replaced = state.current
      state.current = continuation
      state.generation += 1
      state.requests.append(folders)
      let requests = state.requests
      let ready = state.waiters.filter { $0.value.ready(requests) }
      for id in ready.keys { state.waiters[id] = nil }
      return Started(generation: state.generation, ready: ready, replaced: replaced)
    }
    guard let started else { return nil }
    started.replaced?.finish()
    let generation = started.generation
    continuation.onTermination = { [weak self] _ in self?.stopped(generation) }
    for waiter in started.ready.values { waiter.continuation.resume() }
    return stream
  }

  private func stopped(_ generation: Int) {
    state.withLock { state in
      if state.generation == generation { state.current = nil }
    }
  }
}

extension FakeDevice {
  public func watch(_ folders: [FolderHint]) async -> AsyncStream<FolderHint>? {
    watches.start(folders)
  }
}
