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
    // Once an eject has begun, the session is the eject's to close.
    if ejecting.contains(id) { throw .deviceNotFound(id) }
    let session = try session(for: id)
    leases[id, default: 0] += 1
    leasesGranted += 1
    return SessionLease(device: id, session: session)
  }

  public func release(_ lease: SessionLease) {
    let id = lease.device
    let remaining = leases[id, default: 1] - 1
    leases[id] = remaining > 0 ? remaining : nil
    if remaining <= 0 {
      for waiter in drainWaiters.removeValue(forKey: id) ?? [] {
        waiter.resume()
      }
    }
  }

  /// Requests waiting for a swap to finish.
  var requestsAwaitingSwap: Int { swapWaiters.values.map(\.count).reduce(0, +) }

  func isSwapping(_ id: DeviceID) -> Bool { swapping.contains(id) }

  /// Network devices waiting for the user to allow this Mac, as of the most recent scan.
  public func awaitingAuthorization() -> [String] { awaiting }

  /// Whether adb can be used, as of the most recent scan; `nil` before the first, or with no adb.
  public func adbStatus() -> ADBStatus? { adbState }

  /// Devices with USB debugging on that wait for the user to allow this Mac, as of the most
  /// recent scan.
  public func awaitingUSBDebugging() -> [DeviceID] {
    awaitingDebugging.sorted { $0.serial < $1.serial }
  }

  /// Swaps and ejects waiting for a device's requests to finish.
  var waitingForRequests: Int { drainWaiters.values.map(\.count).reduce(0, +) }

  /// Returns once no lease on `id` is out.
  func requestsFinished(_ id: DeviceID) async {
    while leases[id, default: 0] > 0 {
      await withCheckedContinuation { drainWaiters[id, default: []].append($0) }
    }
  }

  /// Returns once no swap of `id` is under way.
  func swapFinished(_ id: DeviceID) async {
    while swapping.contains(id) {
      await withCheckedContinuation { swapWaiters[id, default: []].append($0) }
    }
  }
}

// MARK: Serving

extension DeviceHub {
  /// Opens each usable device the hub does not hold, and moves each held one whose method the
  /// scan says has changed.
  ///
  /// A held device is never moved from USB to the network in place: a cable pull is learnt from
  /// the session reporting the device gone, which detaches it before the network serves it. A
  /// held device a USB route presents but cannot serve (busy, not sharing, or present only to
  /// adb, offline) is let go: the network must not serve it.
  func serve(_ scan: DeviceScan) async {
    for info in scan.devices where !swapping.contains(info.id) && !ejecting.contains(info.id) {
      let method = scan.method(of: info.id)
      if let entry = entries[info.id], case .held = entry.holding {
        guard entry.method != method, method != .wifiADB, swapHolds[info.id]?.waiting != true
        else { continue }
        beginSwap(info.id, to: .method(method))
      } else {
        await admit(info, method: method)
      }
    }
    let usable = Set(scan.devices.map(\.id))
    func listing(_ info: DeviceInfo, _ state: DeviceState) -> (DeviceID, SwapTarget.Listing?) {
      (info.id, SwapTarget.Listing(info: info, state: state, method: scan.method(of: info.id)))
    }
    let unservable =
      scan.busy.map { listing($0, .busy) } + scan.notSharing.map { listing($0, .notSharingFiles) }
      + scan.presentOverUSB.map { ($0, SwapTarget.Listing?.none) }
    for (id, listed) in unservable
    where !usable.contains(id) && !swapping.contains(id) && !ejecting.contains(id) {
      guard let entry = entries[id], case .held = entry.holding else { continue }
      if listed == nil, entry.method != .wifiADB { continue }
      beginSwap(id, to: .released(listed))
    }
  }
}

// MARK: Swapping

/// What a swap leaves a held device on.
enum SwapTarget: Equatable {
  /// A session over this method.
  case method(ConnectionMethod)
  /// No session: a USB route presents the device but cannot serve it (busy, not sharing), so the
  /// network must stop serving it; it is listed as that route lists it. With no listing, the
  /// device is dropped: the USB route lists it nowhere (adb offline).
  case released(Listing?)

  struct Listing: Equatable {
    let info: DeviceInfo
    let state: DeviceState
    let method: ConnectionMethod
  }
}

extension DeviceHub {
  /// Replaces the session of the held device `id`, off the reconcile chain, so a long transfer
  /// that holds a lease does not hold up other devices.
  func beginSwap(_ id: DeviceID, to target: SwapTarget) {
    guard swapping.insert(id).inserted else { return }
    log.info("device \(id.serial, privacy: .private) moving to \(target.name, privacy: .public)")
    requestFreeTask { [weak self] in
      await self?.swap(id, to: target)
    }
  }

  private func swap(_ id: DeviceID, to target: SwapTarget) async {
    defer { endSwap(id) }
    await requestsFinished(id)
    // Nothing else touches the entry while it swaps: probes, ejects and scans of it wait.
    guard let entry = entries[id], case .held(let old) = entry.holding else { return }
    switch target {
    case .released(let listing):
      await old.close()
      await kept.removeValue(forKey: id)?.close()
      if let listing {
        store(listing.info, listing.state, .unheld, method: listing.method)
        // The listing is from before the drain, which can be long: what is attached now decides.
        requestFreeTask { [weak self] in await self?.reconcile() }
      } else {
        drop(id)
      }
    case .method(let method):
      guard entry.method != method else { return }
      if await move(entry, from: old, to: method) {
        swapHolds[id] = nil
      } else {
        holdSwaps(id)
      }
    }
  }

  /// Moves the device to a session over `method`. Returns whether it moved; if not, it is back
  /// on the MTP session it kept, or dropped.
  private func move(_ entry: Entry, from old: any DeviceSession, to method: ConnectionMethod)
    async -> Bool
  {
    let id = entry.info.id
    // Kept, the old MTP session is the one the entry still holds: resuming it after a failed
    // move is no new session, and so takes no new number.
    let resumesHeld = entry.method == .usbFileTransfer
    if resumesHeld {
      kept[id] = old
    } else {
      await old.close()
    }
    if method == .usbFileTransfer, await resumeKept(entry.info, generation: entry.generation) {
      return true
    }
    let session: any DeviceSession
    do throws(TransportError) {
      session = try await transport.open(id)
    } catch {
      let (serial, via, reason) = (id.serial, method.rawValue, String(describing: error))
      log.info(
        "\(serial, privacy: .private) not opened over \(via, privacy: .public): \(reason, privacy: .private)"
      )
      if await resumeKept(entry.info, generation: entry.generation, renumber: !resumesHeld) {
        return false
      }
      drop(id)
      return false
    }
    let reading = await Self.read(session)
    // Leaving a working MTP session for one that cannot read its storages would take the
    // device's domains offline: the move happens only once the new session is ready.
    let usable: Bool
    switch reading {
    case .state(.ready): usable = true
    case .state(let state): usable = !state.isFailure && kept[id] == nil
    case .gone: usable = false
    }
    switch reading {
    case .state(let state) where usable:
      hold(id)
      store(entry.info, state, .held(session), method: await session.method)
      return true
    case .state, .gone:
      await session.close()
      if await resumeKept(entry.info, generation: entry.generation, renumber: !resumesHeld) {
        return false
      }
      drop(id)
      return false
    }
  }

  /// Holds off the next swap attempt of a device whose new session was not ready: 2 s, doubling
  /// to 60 s, then scans again.
  func holdSwaps(_ id: DeviceID) {
    let delay = swapHolds[id].map { min($0.delay * 2, Self.maxRetryDelay) } ?? Self.firstRetryDelay
    generations += 1
    let token = generations
    swapHolds[id] = Backoff(delay: delay, waiting: true, token: token)
    requestFreeTask { [weak self, clock] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      await self?.retrySwap(id, token: token)
    }
  }

  private func retrySwap(_ id: DeviceID, token: UInt64) async {
    guard let hold = swapHolds[id], hold.waiting, hold.token == token else { return }
    swapHolds[id]?.waiting = false
    await reconcile()
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
  /// `renumber` is false when the session is the one the device's entry already holds (a move
  /// away from it failed): clients would read a new number as the device reached again.
  func resumeKept(_ info: DeviceInfo, generation: UInt64, renumber: Bool = true) async -> Bool {
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
    if renumber { hold(info.id) }
    store(info, state, .held(session), method: .usbFileTransfer)
    return true
  }

  /// Forgets a device whose session is gone, closing any session kept for it, and scans again:
  /// a replug of the same device, or another way to reach it, may already be waiting.
  func drop(_ id: DeviceID) {
    entries[id] = nil
    if let session = kept.removeValue(forKey: id) {
      requestFreeTask { await session.close() }
    }
    updatePolling()
    log.info("device \(id.serial, privacy: .private) detached")
    continuation.yield(.detached(id))
    requestFreeTask { [weak self] in await self?.reconcile() }
  }
}

extension SwapTarget {
  fileprivate var name: String {
    switch self {
    case .method(let method): method.rawValue
    case .released(let listing): listing.map { "unserved (\($0.state))" } ?? "unserved"
    }
  }
}

extension DeviceState {
  fileprivate var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}
