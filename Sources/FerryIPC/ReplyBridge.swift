import Foundation
import Synchronization

/// Records whether a continuation has been resumed. XPC may call both the reply block and the
/// proxy's error handler, on different queues, so the first one to arrive wins.
private final class ResumeOnce: Sendable {
  private let resumed = Atomic(false)

  func claim() -> Bool {
    resumed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
      .exchanged
  }
}

/// No reply came within the deadline `awaitReply` was given.
struct ReplyOverdue: Error {}

/// A reply deadline whose clock starts only when `start()` is called: when the agent says the
/// request has its turn at the device. Until then the reply may take as long as the queue does.
/// It runs on `clock`, which a test moves by hand.
final class ReplyDeadline: Sendable {
  private struct State {
    var started = false
    var finished = false
    var expire: (@Sendable () -> Void)?
    var timer: Task<Void, Never>?
  }

  let duration: Duration
  private let clock: any Clock<Duration>
  private let state = Mutex(State())

  init(_ duration: Duration, clock: any Clock<Duration> = ContinuousClock()) {
    self.duration = duration
    self.clock = clock
  }

  /// Starts the clock, once; `awaitReply` sets what happens when it runs out.
  func start() {
    state.withLock { state in
      guard !state.started, !state.finished else { return }
      state.started = true
      arm(&state)
    }
  }

  fileprivate func attach(_ expire: @escaping @Sendable () -> Void) {
    state.withLock { state in
      state.expire = expire
      if state.started { arm(&state) }
    }
  }

  fileprivate func finish() {
    state.withLock { state in
      state.finished = true
      state.timer?.cancel()
      state.timer = nil
    }
  }

  private func arm(_ state: inout State) {
    guard state.timer == nil, let expire = state.expire else { return }
    let (duration, clock) = (duration, clock)
    state.timer = Task {
      guard (try? await clock.sleep(for: duration)) != nil else { return }
      expire()
    }
  }
}

/// Runs `start` with a reply callback and an error callback and returns whichever fires first.
/// If the calling task is cancelled first, it returns a `CancellationError` failure at once and
/// ignores the late reply, so a caller is never held by a request it no longer wants. With a
/// `deadline`, a reply that has not come once it has run out is a `ReplyOverdue` failure, and is
/// ignored too.
func awaitReply(
  isolation: isolated (any Actor)? = #isolation,
  deadline: ReplyDeadline? = nil,
  _ start: (
    _ reply: @escaping @Sendable (Data) -> Void,
    _ failed: @escaping @Sendable (any Error) -> Void
  ) -> Void
) async -> Result<Data, any Error> {
  // An `AsyncStream` iterator ends when its task is cancelled, which a checked continuation
  // cannot do.
  let (results, continuation) = AsyncStream.makeStream(
    of: Result<Data, any Error>.self, bufferingPolicy: .bufferingOldest(1))
  let once = ResumeOnce()
  deadline?.attach {
    if once.claim() { continuation.yield(.failure(ReplyOverdue())) }
  }
  defer { deadline?.finish() }
  start(
    { data in
      if once.claim() { continuation.yield(.success(data)) }
    },
    { error in
      if once.claim() { continuation.yield(.failure(error)) }
    })
  for await result in results {
    return result
  }
  return .failure(CancellationError())
}
