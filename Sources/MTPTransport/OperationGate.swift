import DeviceKit

/// Runs one operation at a time, in the order they arrive.
///
/// An actor alone does not do this: it lets another call in at every `await`, so a session
/// operation could check that a name is free, suspend on USB, and find the name taken by the
/// time it acts. The gate is not reentrant, so an operation must never run another gated one.
actor OperationGate {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Operations queued behind the one running.
  var waiting: Int { waiters.count }

  /// Runs `body` once every operation that arrived earlier has finished. `body` stays on the
  /// caller's actor; only the turn-taking happens here.
  func run<T, E: Error>(
    isolation: isolated (any Actor)? = #isolation, _ body: () async throws(E) -> T
  ) async throws(E) -> T {
    await acquire()
    let result: Result<T, E>
    do throws(E) {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    await release()
    return try result.get()
  }

  private func acquire() async {
    guard busy else {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  /// Hands the gate straight to the next waiter, so nothing can slip in between.
  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
