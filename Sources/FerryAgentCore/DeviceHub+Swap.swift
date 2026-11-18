import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DeviceHub")

/// A request's hold on a device's session: the hub does not replace the session while any lease
/// on the device is out.
public struct SessionLease: Sendable {
  public let device: DeviceID
  public let session: any DeviceSession
}

// MARK: Leases

extension DeviceHub {
  /// The session serving `id`, held for one request until `release(_:)`. While the hub is
  /// replacing the device's session, waits for the new one.
  public func lease(_ id: DeviceID) async throws(TransportError) -> SessionLease {
    await swapFinished(id)
    let session = try session(for: id)
    leases[id, default: 0] += 1
    return SessionLease(device: id, session: session)
  }

  public func release(_ lease: SessionLease) {
    let id = lease.device
    let remaining = leases[id, default: 1] - 1
    leases[id] = remaining > 0 ? remaining : nil
    if remaining <= 0 { drainWaiters.removeValue(forKey: id)?.resume() }
  }

  /// Requests waiting for a swap to finish.
  var requestsAwaitingSwap: Int { swapWaiters.values.map(\.count).reduce(0, +) }

  func isSwapping(_ id: DeviceID) -> Bool { swapping.contains(id) }

  /// Returns once no swap of `id` is under way.
  func swapFinished(_ id: DeviceID) async {
    while swapping.contains(id) {
      await withCheckedContinuation { swapWaiters[id, default: []].append($0) }
    }
  }
}

// MARK: Swapping

extension DeviceHub {
  /// Replaces the session of the held device `id` with one over `method`, off the reconcile
  /// chain, so a long transfer that holds a lease does not hold up other devices.
  func beginSwap(_ id: DeviceID, to method: ConnectionMethod) {
    guard swapping.insert(id).inserted else { return }
    log.info(
      "device \(id.serial, privacy: .private) moving to \(method.rawValue, privacy: .public)")
    Task { [weak self] in
      await self?.swap(id, to: method)
    }
  }

  private func swap(_ id: DeviceID, to method: ConnectionMethod) async {
    defer { endSwap(id) }
    if leases[id, default: 0] > 0 {
      await withCheckedContinuation { drainWaiters[id] = $0 }
    }
    // Nothing else touches the entry while it swaps: probes, ejects and scans of it wait.
    guard let entry = entries[id], case .held(let old) = entry.holding, entry.method != method
    else { return }
    if entry.method == .usbFileTransfer {
      kept[id] = old
    } else {
      await old.close()
    }
    if method == .usbFileTransfer, await resumeKept(entry.info, generation: entry.generation) {
      return
    }
    let session: any DeviceSession
    do throws(TransportError) {
      session = try await transport.open(id)
    } catch {
      let (serial, via, reason) = (id.serial, method.rawValue, String(describing: error))
      log.info(
        "\(serial, privacy: .private) not opened over \(via, privacy: .public): \(reason, privacy: .private)"
      )
      if await resumeKept(entry.info, generation: entry.generation) { return }
      drop(id)
      return
    }
    let reading = await Self.read(session)
    switch reading {
    case .state(let state) where !state.isFailure:
      store(entry.info, state, .held(session), method: method)
    case .state, .gone:
      await session.close()
      if await resumeKept(entry.info, generation: entry.generation) { return }
      drop(id)
    }
  }

  func endSwap(_ id: DeviceID) {
    swapping.remove(id)
    for waiter in swapWaiters.removeValue(forKey: id) ?? [] {
      waiter.resume()
    }
  }
}

// MARK: Kept sessions

extension DeviceHub {
  /// Serves the device from its kept MTP session, if it has one that still answers. One that
  /// does not is closed. Counts as a swap while it reads, so no scan reopens the device meanwhile.
  func resumeKept(_ info: DeviceInfo, generation: UInt64) async -> Bool {
    guard let session = kept.removeValue(forKey: info.id) else { return false }
    let owned = swapping.insert(info.id).inserted
    defer { if owned { endSwap(info.id) } }
    let reading = await Self.read(session)
    guard entries[info.id]?.generation == generation, case .state(let state) = reading else {
      await session.close()
      return false
    }
    if case .failed = state {
      await session.close()
      return false
    }
    log.info("device \(info.id.serial, privacy: .private) back on file transfer")
    store(info, state, .held(session), method: .usbFileTransfer)
    return true
  }

  /// Forgets a device whose session is gone, closing any session kept for it, and scans again:
  /// a replug of the same device, or another way to reach it, may already be waiting.
  func drop(_ id: DeviceID) {
    entries[id] = nil
    if let session = kept.removeValue(forKey: id) {
      Task { await session.close() }
    }
    updatePolling()
    log.info("device \(id.serial, privacy: .private) detached")
    continuation.yield(.detached(id))
    Task { [weak self] in await self?.reconcile() }
  }
}

extension DeviceState {
  fileprivate var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}
