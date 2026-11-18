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
/// If the calling task is cancelled first, it returns a `CancellationError` failure at once and
/// ignores the late reply, so a caller is never held by a request it no longer wants.
func awaitReply(
  isolation: isolated (any Actor)? = #isolation,
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
