import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// The agent waits for start-up work (replacing an earlier agent's adb server) before its XPC
/// listener is up. However that work hangs, the agent goes on to serve within the bound.
struct AgentStartupTests {
  @Test(.timeLimit(.minutes(1)))
  func workThatNeverEndsIsAbandonedAtTheBound() {
    let began = ContinuousClock.now
    let finished = AgentStartup.wait(upTo: .milliseconds(300)) {
      await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    #expect(finished == false)
    #expect(began.duration(to: .now) < .seconds(2))
  }

  @Test(.timeLimit(.minutes(1)))
  func workThatEndsIsWaitedFor() {
    let done = Box()
    let finished = AgentStartup.wait(upTo: .seconds(10)) {
      try? await Task.sleep(for: .milliseconds(50))
      done.set()
    }
    #expect(finished)
    #expect(done.isSet)
  }

  final class Box: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
  }
}
