import FileProvider
import Synchronization
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "PendingProbe")

/// Asks a domain's pending set (`NSFileProviderManager.enumeratorForPendingItems`, macOS 11.3)
/// whether it holds anything: the items the system has not yet had the extension apply, which
/// for a hidden domain are changes waiting for its device.
final class PendingProbe: NSObject, NSFileProviderEnumerationObserver, Sendable {
  private let state = Mutex<(waiter: CheckedContinuation<Bool, Never>?, answer: Bool?)>((nil, nil))

  /// Whether the first page of `enumerator` holds any item. The answer comes within `limit`,
  /// `false` when the system has not said by then, so a status request never waits on it.
  static func anyItem(in enumerator: any NSFileProviderEnumerator, within limit: Duration) async
    -> Bool
  {
    let probe = PendingProbe()
    enumerator.enumerateItems(
      for: probe, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
    )
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { await probe.answer() }
      group.addTask {
        try? await Task.sleep(for: limit)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
    if !updatedItems.isEmpty { finish(true) }
  }

  func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
    finish(false)
  }

  func finishEnumeratingWithError(_ error: any Error) {
    log.error("listing pending items failed: \(error, privacy: .private)")
    finish(false)
  }

  private func answer() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiter in
        let known: Bool? = state.withLock { state in
          if let answer = state.answer { return answer }
          state.waiter = waiter
          return nil
        }
        if let known { waiter.resume(returning: known) }
      }
    } onCancel: {
      finish(false)
    }
  }

  /// Settles the answer once; later calls change nothing.
  private func finish(_ answer: Bool) {
    let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard state.answer == nil else { return nil }
      state.answer = answer
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(returning: answer)
  }
}
