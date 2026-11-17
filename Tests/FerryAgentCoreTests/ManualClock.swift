import Synchronization

/// A clock that moves only when a test calls `advance(by:)`.
final class ManualClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    let offset: Duration

    func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private let nanoseconds = Atomic<Int64>(0)
  private let sleepers = Sleepers()

  var now: Instant {
    Instant(offset: .nanoseconds(nanoseconds.load(ordering: .acquiring)))
  }

  var minimumResolution: Duration { .nanoseconds(1) }

  /// Sleeps requested so far, finished or not.
  var sleepCount: Int {
    get async { await sleepers.count }
  }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try await sleepers.sleep(until: deadline, now: now)
  }

  /// Moves time forward and wakes every sleeper whose deadline has passed.
  func advance(by duration: Duration) async {
    let (seconds, attoseconds) = duration.components
    nanoseconds.add(seconds * 1_000_000_000 + attoseconds / 1_000_000_000, ordering: .releasing)
    await sleepers.wake(upTo: now)
  }

  /// Returns once someone is sleeping on this clock.
  func waitForSleeper() async {
    await sleepers.waitForSleeper()
  }
}

private actor Sleepers {
  private struct Sleeper {
    let id: Int
    let deadline: ManualClock.Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private(set) var count = 0
  private var sleeping: [Sleeper] = []
  private var cancelled: Set<Int> = []
  private var watchers: [CheckedContinuation<Void, Never>] = []

  func sleep(until deadline: ManualClock.Instant, now: ManualClock.Instant) async throws {
    count += 1
    guard deadline > now else { return }
    let id = count
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(Sleeper(id: id, deadline: deadline, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  private func register(_ sleeper: Sleeper) {
    if cancelled.remove(sleeper.id) != nil {
      sleeper.continuation.resume(throwing: CancellationError())
      return
    }
    sleeping.append(sleeper)
    for watcher in watchers { watcher.resume() }
    watchers = []
  }

  func wake(upTo now: ManualClock.Instant) {
    let due = sleeping.filter { $0.deadline <= now }
    sleeping.removeAll { $0.deadline <= now }
    for sleeper in due { sleeper.continuation.resume() }
  }

  func waitForSleeper() async {
    guard sleeping.isEmpty else { return }
    await withCheckedContinuation { watchers.append($0) }
  }

  private func cancel(_ id: Int) {
    guard let index = sleeping.firstIndex(where: { $0.id == id }) else {
      cancelled.insert(id)
      return
    }
    sleeping.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
