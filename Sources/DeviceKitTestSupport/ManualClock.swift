import Synchronization

/// A clock that moves only when a test calls `advance(by:)`.
public final class ManualClock: Clock, Sendable {
  public struct Instant: InstantProtocol {
    public let offset: Duration

    public func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    public func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private let nanoseconds = Atomic<Int64>(0)
  private let sleepers = Sleepers()

  public init() {}

  public var now: Instant {
    Instant(offset: .nanoseconds(nanoseconds.load(ordering: .acquiring)))
  }

  public var minimumResolution: Duration { .nanoseconds(1) }

  /// Sleeps requested so far, finished or not.
  public var sleepCount: Int {
    get async { await sleepers.count }
  }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try await sleepers.sleep(until: deadline, now: now)
  }

  /// Moves time forward and wakes every sleeper whose deadline has passed.
  public func advance(by duration: Duration) async {
    let (seconds, attoseconds) = duration.components
    nanoseconds.add(seconds * 1_000_000_000 + attoseconds / 1_000_000_000, ordering: .releasing)
    await sleepers.wake(upTo: now)
  }

  /// Returns once someone is sleeping on this clock.
  public func waitForSleeper() async {
    await sleepers.waitForSleeper()
  }

  /// Returns once `count` sleeps have been requested in all, finished or not, or the calling
  /// task is cancelled.
  public func waitForSleeps(_ count: Int) async {
    await sleepers.waitForCount(count)
  }

  /// Runs `operation`, moving time on by `step` again and again until it returns: every wait it
  /// makes on this clock passes, however many there are and whenever each begins. For an
  /// operation that must time out, once the test has seen it reach the wait that does. Time moves
  /// only while something sleeps on the clock, so the ticks never spin with nobody waiting.
  public func advancing<T>(by step: Duration, _ operation: () async throws -> T) async rethrows
    -> T
  {
    let ticking = Task {
      while !Task.isCancelled {
        await waitForSleeper()
        await advance(by: step)
        await Task.yield()
      }
    }
    defer { ticking.cancel() }
    return try await operation()
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
  private var watchers: [Int: CheckedContinuation<Void, Never>] = [:]
  private var countWatchers: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] =
    [:]
  private var nextWatcher = 0

  func sleep(until deadline: ManualClock.Instant, now: ManualClock.Instant) async throws {
    count += 1
    let reached = countWatchers.filter { $0.value.count <= count }
    for (id, watcher) in reached {
      countWatchers[id] = nil
      watcher.continuation.resume()
    }
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
    for watcher in watchers.values { watcher.resume() }
    watchers = [:]
  }

  func wake(upTo now: ManualClock.Instant) {
    let due = sleeping.filter { $0.deadline <= now }
    sleeping.removeAll { $0.deadline <= now }
    for sleeper in due { sleeper.continuation.resume() }
  }

  /// Returns once something sleeps, or the calling task is cancelled, as a test's time limit
  /// does, so a sleep that never comes fails the test instead of hanging it.
  func waitForSleeper() async {
    guard sleeping.isEmpty, !Task.isCancelled else { return }
    nextWatcher += 1
    let id = nextWatcher
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          watchers[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.stopWatching(id) }
    }
  }

  private func stopWatching(_ id: Int) {
    watchers.removeValue(forKey: id)?.resume()
    countWatchers.removeValue(forKey: id)?.continuation.resume()
  }

  /// Returns once `target` sleeps have been requested, or the calling task is cancelled.
  func waitForCount(_ target: Int) async {
    guard count < target, !Task.isCancelled else { return }
    nextWatcher += 1
    let id = nextWatcher
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          countWatchers[id] = (target, continuation)
        }
      }
    } onCancel: {
      Task { await self.stopWatching(id) }
    }
  }

  private func cancel(_ id: Int) {
    guard let index = sleeping.firstIndex(where: { $0.id == id }) else {
      cancelled.insert(id)
      return
    }
    sleeping.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
