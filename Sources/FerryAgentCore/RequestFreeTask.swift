import DeviceKit
import FerryIPC

/// Starts `operation` as an unstructured task that belongs to no request. A `Task {}` copies the
/// starting task's task-locals, so hub and domain work started while a request runs would
/// otherwise keep that request's `DeviceTurns.current` and `RequestCancellation.current` (and,
/// through it, the client's XPC proxy) for its whole life, and a cancelled request's turn would
/// refuse every device call it makes.
@discardableResult
func requestFreeTask<T: Sendable>(_ operation: @escaping @Sendable () async -> T)
  -> Task<T, Never>
{
  Task {
    await RequestCancellation.$current.withValue(nil) {
      await DeviceTurns.$current.withValue(nil) { await operation() }
    }
  }
}
