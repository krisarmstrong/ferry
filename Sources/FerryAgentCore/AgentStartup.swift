import Foundation

/// Work the agent finishes before it serves, from its synchronous top-level code (an `await`
/// there would make main.swift an async main, where `dispatchMain()` traps).
public enum AgentStartup {
  /// Runs `work` off the main thread and waits for it, at most `limit`. Returns whether it
  /// finished; work still running then carries on unwaited.
  public static func wait(upTo limit: Duration, for work: @escaping @Sendable () async -> Void)
    -> Bool
  {
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
      await work()
      finished.signal()
    }
    let (seconds, attoseconds) = limit.components
    let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
    return finished.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
  }
}
