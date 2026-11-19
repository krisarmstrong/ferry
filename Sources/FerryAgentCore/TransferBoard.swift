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
  /// Devices whose adb is restarting (Use over Wi-Fi), with the transfers waiting for it.
  private var restarting: [DeviceID: [UUID: CheckedContinuation<Void, Never>]] = [:]

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
    try await begin(id, start, cancellation: cancellation)
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

  /// Marks the device's adb as restarting, if no transfer runs on it: one that starts meanwhile
  /// waits for `endRestart`, so the restart never cuts one off. The check and the mark are one
  /// step on this actor. False if a transfer runs, or a restart is already under way.
  func beginRestart(_ device: DeviceID) -> Bool {
    guard restarting[device] == nil, !active.contains(where: { $0.transfer.device == device })
    else { return false }
    restarting[device] = [:]
    return true
  }

  func endRestart(_ device: DeviceID) {
    for waiter in (restarting.removeValue(forKey: device) ?? [:]).values { waiter.resume() }
  }

  /// Lists the transfer, once no restart of its device is under way. A client's cancel ends the
  /// wait at once, before the transfer touches the device.
  private func begin(
    _ id: UUID, _ transfer: ActiveTransfer, cancellation: RequestCancellation?
  ) async throws(TransportError) {
    let device = transfer.device
    while restarting[device] != nil {
      if cancellation?.isCancelled == true { throw .cancelled }
      let token = UUID()
      // The wake-up reaches this actor only once the wait below is stored.
      cancellation?.whenCancelled { [weak self] in
        Task { await self?.wake(device, token) }
      }
      await withCheckedContinuation { restarting[device]?[token] = $0 }
    }
    active.append((id, transfer))
  }

  private func wake(_ device: DeviceID, _ token: UUID) {
    restarting[device]?.removeValue(forKey: token)?.resume()
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
