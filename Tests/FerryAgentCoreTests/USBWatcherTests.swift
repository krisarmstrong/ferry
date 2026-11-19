import FerryIPC
import Synchronization
import Testing

@testable import FerryAgentCore

/// Stands in for IOKit: fails to arm a set number of times, then arms and ticks as the monitor
/// does.
private actor FakeArming: USBArming {
  private let continuation: AsyncStream<Void>.Continuation
  private var failures: Int
  private(set) var attempts = 0
  private(set) var stopped = false

  init(continuation: AsyncStream<Void>.Continuation, failures: Int) {
    self.continuation = continuation
    self.failures = failures
  }

  func arm() -> Bool {
    attempts += 1
    guard failures == 0 else {
      failures -= 1
      return false
    }
    continuation.yield()
    return true
  }

  func stop() {
    stopped = true
  }
}

@Suite(.timeLimit(.minutes(1)))
struct USBWatcherTests {
  /// IOKit refusing the notifications does not end the stream, which would stop the hub for
  /// good: the state says so, the stream keeps ticking so the hub scans, and arming is retried
  /// until it works.
  @Test func anArmFailureIsShownTickedAndRetried() async throws {
    let state = USBWatchState()
    let made = Mutex<FakeArming?>(nil)
    let stream = USBWatcher.ticks(state: state, retryInterval: .milliseconds(20)) {
      let arming = FakeArming(continuation: $0, failures: 2)
      made.withLock { $0 = arming }
      return arming
    }
    var ticks = stream.makeAsyncIterator()
    #expect(await ticks.next() != nil)
    #expect(state.failed)
    let arming = try #require(made.withLock { $0 })
    // Ticks coalesce, so the retries are seen in the attempts, not counted in ticks.
    while await arming.attempts < 3 || state.failed {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await arming.attempts == 3)
    #expect(await ticks.next() != nil)
  }

  @Test func endingTheStreamStopsTheMonitor() async throws {
    let made = Mutex<FakeArming?>(nil)
    var stream: AsyncStream<Void>? = USBWatcher.ticks(
      state: USBWatchState(), retryInterval: .milliseconds(20)
    ) {
      let arming = FakeArming(continuation: $0, failures: 0)
      made.withLock { $0 = arming }
      return arming
    }
    var ticks = stream?.makeAsyncIterator()
    #expect(await ticks?.next() != nil)
    stream = nil
    ticks = nil
    let arming = try #require(made.withLock { $0 })
    while await !arming.stopped {
      await Task.yield()
    }
  }

  /// The status carries the watcher's state to the menu.
  @Test func theStatusSaysWhetherUSBIsWatched() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let state = USBWatchState()
    let service = AgentService(hub: harness.hub, domains: harness.controller, usbWatch: state)
    harness.tick()
    guard case .status(let watched) = await service.handle(.status, file: nil) else {
      Issue.record("no status")
      return
    }
    #expect(!watched.usbWatchFailed)
    state.set(failed: true)
    guard case .status(let unwatched) = await service.handle(.status, file: nil) else {
      Issue.record("no status")
      return
    }
    #expect(unwatched.usbWatchFailed)
  }
}
