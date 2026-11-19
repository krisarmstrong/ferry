import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import os

/// The transfers the agent is running, for the menu, and the path their progress takes from the
/// device to the client.
///
/// libmtp reports progress on the device's queue, synchronously and as often as every block, so
/// the handler it gets only yields to a stream that keeps the newest value. One task per
/// transfer reads that stream at most four times a second, records the value here and reports
/// it to the client, and a transfer that succeeds reports its whole size last, so the client
/// sees it complete before the reply. The handler answers "stop" once the client has cancelled
/// the request (`RequestCancellation`), so the transfer ends at its next block.
actor TransferBoard {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "Transfers")

  private var active: [(id: UUID, transfer: ActiveTransfer)] = []

  static let interval = Duration.milliseconds(250)

  /// Running transfers, oldest first.
  func list() -> [ActiveTransfer] {
    active.map(\.transfer)
  }

  /// Runs `body` as the transfer `start` describes, listed here until it ends.
  nonisolated func track<T: Sendable>(
    _ start: ActiveTransfer, report: @escaping TransferProgressHandler,
    _ body: (_ progress: @escaping ProgressHandler) async throws(TransportError) -> T
  ) async throws(TransportError) -> T {
    let id = UUID()
    let cancellation = RequestCancellation.current
    let latestTotal = LatestTotal()
    let (values, continuation) = AsyncStream.makeStream(
      of: (UInt64, UInt64).self, bufferingPolicy: .bufferingNewest(1))
    await begin(id, start)
    let pump = Task {
      for await (completed, total) in values {
        await update(id, completed: completed, total: total)
        report(completed, total)
        Self.log.debug("progress \(completed, privacy: .public) of \(total, privacy: .public)")
        try? await Task.sleep(for: Self.interval)
      }
    }
    let result: Result<T, TransportError>
    do throws(TransportError) {
      result = .success(
        try await body { completed, total in
          latestTotal.value.store(total, ordering: .relaxed)
          continuation.yield((completed, total))
          return cancellation?.isCancelled != true
        })
    } catch {
      result = .failure(error)
    }
    continuation.finish()
    pump.cancel()
    await pump.value
    await end(id)
    if case .success = result {
      let total = latestTotal.value.load(ordering: .relaxed)
      report(total, total)
    }
    return try result.get()
  }

  private func begin(_ id: UUID, _ transfer: ActiveTransfer) {
    active.append((id, transfer))
  }

  private func update(_ id: UUID, completed: UInt64, total: UInt64) {
    guard let index = active.firstIndex(where: { $0.id == id }) else { return }
    let old = active[index].transfer
    active[index].transfer = ActiveTransfer(
      device: old.device, name: old.name, direction: old.direction, completed: completed,
      total: total)
  }

  private func end(_ id: UUID) {
    active.removeAll { $0.id == id }
  }
}

/// The total the device last reported for a transfer, written on the device's queue.
private final class LatestTotal: Sendable {
  let value = Atomic<UInt64>(0)
}
