import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// The agent waits for start-up work (replacing an earlier agent's adb server) before its XPC
/// listener is up. However that work hangs, the agent goes on to serve within the bound.
struct AgentStartupTests {
  /// `wait` blocks its thread, as the agent's top-level code does, while the work it waits for
  /// needs a thread of the shared pool. Called from a dispatch thread, so a test never holds a
  /// pool thread that the work is waiting for.
  static func wait(upTo limit: Duration, for work: @escaping @Sendable () async -> Void) async
    -> Bool
  {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: AgentStartup.wait(upTo: limit, for: work))
      }
    }
  }

  /// It returns at all, though the work never ends: the bound let it go.
  @Test(.timeLimit(.minutes(1)))
  func workThatNeverEndsIsAbandonedAtTheBound() async {
    let finished = await Self.wait(upTo: .milliseconds(300)) {
      await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    #expect(finished == false)
  }

  @Test(.timeLimit(.minutes(1)))
  func workThatEndsIsWaitedFor() async {
    let done = Box()
    let finished = await Self.wait(upTo: .seconds(10)) {
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
