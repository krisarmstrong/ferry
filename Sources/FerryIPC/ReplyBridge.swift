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

/// Runs `start` with a reply callback and an error callback and returns whichever fires first.
func awaitReply(
  isolation: isolated (any Actor)? = #isolation,
  _ start: (
    _ reply: @escaping @Sendable (Data) -> Void,
    _ failed: @escaping @Sendable (any Error) -> Void
  ) -> Void
) async -> Result<Data, any Error> {
  await withCheckedContinuation { continuation in
    let once = ResumeOnce()
    start(
      { data in
        if once.claim() { continuation.resume(returning: .success(data)) }
      },
      { error in
        if once.claim() { continuation.resume(returning: .failure(error)) }
      })
  }
}
