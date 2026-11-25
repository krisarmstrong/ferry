import DeviceKit
import FerryIPC
import Synchronization

/// Fails work that stops making progress. A move on a device without MoveObject is a whole
/// copy, which may rightly take long (see `AgentRequest.mayTakeLong`); what it must not do is
/// stop. Its transfer arms a `TransferHeartbeat` and beats it at each block, and once `limit`
/// passes with no beat the request is cancelled, so the copy stops at its next block, and failed with
/// `.deviceBusy` at once, which FileProvider tries again later. A device stuck inside one call
/// still holds its session until that call returns. Work that never arms the heartbeat (a native
/// MoveObject, which a device may take minutes over across storages, reporting nothing) is never
/// failed: stopping Ferry's side would leave the device mid-move while Finder heard "busy".
enum StallWatch {
  static func run<T: Sendable>(
    limit: Duration, clock: any Clock<Duration>,
    _ body: @escaping @Sendable () async throws(TransportError) -> T
  ) async throws(TransportError) -> T {
    let heartbeat = TransferHeartbeat()
    let cancellation = RequestCancellation.current
    let answer = StallAnswer<T>()
    let result = await withCheckedContinuation { continuation in
      answer.wait(continuation)
      let watchdog = Task {
        var seen = heartbeat.count
        while true {
          do {
            try await clock.sleep(for: limit)
          } catch {
            return
          }
          let now = heartbeat.count
          if heartbeat.isArmed, now == seen {
            cancellation?.cancel()
            answer.give(.failure(.deviceBusy))
            return
          }
          seen = now
        }
      }
      Task {
        let result = await TransferHeartbeat.$current.withValue(heartbeat) {
          () async -> Result<T, TransportError> in
          do throws(TransportError) {
            return .success(try await body())
          } catch {
            return .failure(error)
          }
        }
        watchdog.cancel()
        answer.give(result)
      }
    }
    return try result.get()
  }
}

/// The first result given, handed to the one waiting for it.
private final class StallAnswer<T: Sendable>: Sendable {
  typealias Waiter = CheckedContinuation<Result<T, TransportError>, Never>
  private let state = Mutex<(given: Bool, waiter: Waiter?)>((false, nil))

  func wait(_ continuation: Waiter) {
    state.withLock { $0.waiter = continuation }
  }

  func give(_ result: Result<T, TransportError>) {
    let waiter = state.withLock { state -> Waiter? in
      guard !state.given else { return nil }
      state.given = true
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(returning: result)
  }
}
