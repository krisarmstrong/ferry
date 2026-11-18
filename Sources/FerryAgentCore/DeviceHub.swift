import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DeviceHub")

/// The one owner of every open device session in the agent.
///
/// Each USB tick on `arrivals` makes the hub scan the bus once, open the new devices, and ask
/// each held session for its storages. A held device's departure is learned only from its own
/// session reporting `.deviceDisconnected`: the transport reports a held device from its record
/// without touching it, so a scan says nothing about whether it is still there. A device another
/// app holds is listed as `.busy`, and one the transport sees without file transfer as
/// `.notSharingFiles`, until it leaves a scan; `recheck` on either asks the transport to try it
/// again. A held session whose storages fail for any other reason than a lock or a departure is
/// closed, so a later scan can open it afresh. Any device a scan reports as usable and the hub
/// does not hold is opened: the transport, not the hub, keeps an ejected device out of that list.
///
/// A device that is attached but not sharing files is re-checked every two seconds. MTP has no
/// event for "file transfer turned on", so this is the hub's one poll, and it runs only while
/// such a device is held.
public actor DeviceHub {
  private enum Holding {
    case held(any DeviceSession)
    /// No session open: ejected, held by another app, or failed to open.
    case unheld
  }

  private struct Entry {
    var info: DeviceInfo
    var state: DeviceState
    var holding: Holding
    /// Renewed on every store, so a result read across a suspension is dropped once the entry
    /// it was read for has been replaced, ejected or removed.
    var generation: UInt64
  }

  private enum Reading {
    case state(DeviceState)
    case gone
  }

  static let recheckInterval = Duration.seconds(2)

  /// Device changes, in order. Single consumer: iterate it from one task only, since an
  /// `AsyncStream` hands each event to just one of its iterators.
  public nonisolated let events: AsyncStream<HubEvent>
  private let continuation: AsyncStream<HubEvent>.Continuation
  private let transport: any DeviceTransport
  let clock: any Clock<Duration>
  private var entries: [DeviceID: Entry] = [:]
  /// Devices the user ejected. Closing one can reset it into a new enumeration that the
  /// transport may offer as usable again, so the hub never opens these until the user mounts
  /// it again (`recheck`) or it is unplugged: no list of a scan names it, which the transport
  /// ensures only once the device has been gone long enough to count as unplugged.
  private var ejected: Set<DeviceID> = []
  /// The scan the transport asked for, without waiting for a USB event.
  var rescan: Task<Void, Never>?
  /// Devices whose storages or open failed, with the wait before the next try. Each close of a
  /// failing Android unit can reset it into a new enumeration and a new tick, so without this a
  /// broken device would be opened again and again.
  var backoff: [DeviceID: Backoff] = [:]

  struct Backoff {
    var delay: Duration
    var waiting: Bool
    /// The wait this entry is for, so a wait from before a Try Again cannot end a later one.
    let token: UInt64
  }

  static let firstRetryDelay = Duration.seconds(2)
  static let maxRetryDelay = Duration.seconds(60)
  var generations: UInt64 = 0
  /// Held devices with a tick's storage read still in flight.
  private var probing: Set<DeviceID> = []
  /// The reconcile most recently asked for; the next one waits for it.
  private var lastReconcile: Task<Void, Never>?
  private var poller: Task<Void, Never>?

  var isRechecking: Bool { poller != nil }

  /// Set once the first reconcile has finished, whether or not its scan worked.
  private var scanned = false
  private var scanWaiters: [CheckedContinuation<Void, Never>] = []
  /// Requests waiting for the hub's first scan.
  var requestsAwaitingFirstScan: Int { scanWaiters.count }

  /// `arrivals` ticks on any USB attach or detach; the hub also reconciles once at start.
  public init(
    transport: any DeviceTransport, arrivals: AsyncStream<Void>,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    (events, continuation) = AsyncStream.makeStream(of: HubEvent.self)
    self.transport = transport
    self.clock = clock
    Task { [weak self] in
      await self?.reconcile()
      await self?.markScanned()
      for await _ in arrivals {
        guard let self else { return }
        await self.reconcile()
      }
    }
  }

  deinit {
    continuation.finish()
  }

  /// Returns once the hub has scanned the bus for the first time. Until then `devices()` would
  /// leave out a device that is plugged in.
  public func firstScan() async {
    guard !scanned else { return }
    await withCheckedContinuation { scanWaiters.append($0) }
  }

  private func markScanned() {
    scanned = true
    for waiter in scanWaiters {
      waiter.resume()
    }
    scanWaiters = []
  }

  public func devices() -> [AttachedDevice] {
    entries.values.map { AttachedDevice(info: $0.info, state: $0.state) }
      .sorted { $0.id.serial < $1.id.serial }
  }

  /// The session the hub holds for `id`. The hub never opens a device a second time.
  public func session(for id: DeviceID) throws(TransportError) -> any DeviceSession {
    guard let entry = entries[id] else { throw .deviceNotFound(id) }
    switch (entry.holding, entry.state) {
    case (.held(let session), _): return session
    case (.unheld, .busy): throw .deviceBusy
    case (.unheld, .failed(let error)): throw error
    case (.unheld, _): throw .deviceNotFound(id)
    }
  }

  /// The user's Try Again: re-reads a held device's storages, for instance after file transfer
  /// was turned on. A device the hub does not hold (busy, failed, not sharing, ejected) is
  /// offered to the transport again and the bus scanned.
  public func recheck(_ id: DeviceID) async {
    guard let entry = entries[id] else { return }
    guard case .held = entry.holding else {
      ejected.remove(id)
      backoff[id] = nil
      await transport.unpark(id)
      await reconcile()
      return
    }
    await recheckHeld(id)
  }

  /// Re-reads a held device's storages. The hub's own probes and polls use this, never
  /// `recheck`, so a device ejected while they run is never offered to the transport again.
  private func recheckHeld(_ id: DeviceID) async {
    guard let entry = entries[id], case .held(let session) = entry.holding else { return }
    let reading = await Self.read(session)
    guard let current = entries[id], current.generation == entry.generation else { return }
    switch reading {
    case .state(.failed(let error)):
      // Let the session go, so a later scan can open the device afresh.
      await session.close()
      guard let latest = entries[id], latest.generation == current.generation else { return }
      store(latest.info, .failed(error), .unheld)
      backOff(id)
    case .state(let state):
      store(current.info, state, current.holding)
    case .gone:
      // Closed while still listed as held, so a replug of the same device ticked meanwhile is
      // not admitted, and reported, ahead of this departure.
      await session.close()
      guard entries[id]?.generation == current.generation else { return }
      entries[id] = nil
      updatePolling()
      log.info("device \(id.serial, privacy: .private) detached")
      continuation.yield(.detached(id))
      // A replug of the same device may already have been ticked while this one was held.
      Task { [weak self] in await self?.reconcile() }
    }
  }

  /// Closes the device's session. It stays listed as `.ejected` until it is unplugged or mounted
  /// again: the transport is told to leave it alone first, so no scan opens it meanwhile.
  public func eject(_ id: DeviceID) async {
    guard case .held = entries[id]?.holding else { return }
    ejected.insert(id)
    await transport.park(id)
    guard let entry = entries[id], case .held(let session) = entry.holding else { return }
    store(entry.info, .ejected, .unheld)
    await session.close()
    log.info("device \(id.serial, privacy: .private) ejected")
  }

  // MARK: Reconcile

  /// Reconciles run one at a time, in the order they were asked for.
  func reconcile() async {
    let previous = lastReconcile
    let current = Task { [weak self] in
      await previous?.value
      await self?.refresh()
    }
    lastReconcile = current
    await current.value
  }

  private func refresh() async {
    for (id, entry) in entries {
      if case .held = entry.holding { probe(id) }
    }
    let scan: DeviceScan
    do throws(TransportError) {
      scan = try await transport.scan()
    } catch {
      log.error("scanning devices failed: \(String(describing: error), privacy: .private)")
      return
    }
    scheduleRescan(after: scan.rescanAfter)
    let present = Set((scan.devices + scan.busy + scan.notSharing + scan.ejected).map(\.id))
    for (id, entry) in entries where !present.contains(id) {
      guard case .unheld = entry.holding else { continue }
      entries[id] = nil
      ejected.remove(id)
      backoff[id] = nil
      log.info("device \(id.serial, privacy: .private) detached")
      continuation.yield(.detached(id))
    }
    for info in scan.busy where isUnheld(info.id) {
      store(info, .busy, .unheld)
    }
    for info in scan.notSharing where isUnheld(info.id) {
      store(info, .notSharingFiles, .unheld)
    }
    for info in scan.ejected where isUnheld(info.id) {
      ejected.insert(info.id)
      store(info, .ejected, .unheld)
    }
    for info in scan.devices {
      await admit(info)
    }
  }

  /// Opens a device the hub does not hold: one it does not list yet, or one that was busy,
  /// failed, or not sharing files and is now offered as usable.
  private func admit(_ info: DeviceInfo) async {
    let existing = entries[info.id]
    if let existing, case .held = existing.holding { return }
    if ejected.contains(info.id) || backoff[info.id]?.waiting == true { return }
    let generation = existing?.generation
    let session: any DeviceSession
    do throws(TransportError) {
      session = try await transport.open(info.id)
    } catch .deviceNotFound {
      return
    } catch {
      guard entries[info.id]?.generation == generation else { return }
      store(info, error == .deviceBusy ? .busy : .failed(error), .unheld)
      if error != .deviceBusy { backOff(info.id) }
      return
    }
    let reading = await Self.read(session)
    guard entries[info.id]?.generation == generation, case .state(let state) = reading else {
      await session.close()
      return
    }
    if case .failed = state {
      await session.close()
      guard entries[info.id]?.generation == generation else { return }
      store(info, state, .unheld)
      backOff(info.id)
      return
    }
    backoff[info.id] = nil
    log.info("device \(info.id.serial, privacy: .private) opened")
    store(info, state, .held(session))
  }

  /// Reads a held device's storages off this tick, so a long transfer queued on its session
  /// does not hold up other devices.
  private func probe(_ id: DeviceID) {
    guard probing.insert(id).inserted else { return }
    Task { [weak self] in
      await self?.recheckHeld(id)
      await self?.probed(id)
    }
  }

  private func probed(_ id: DeviceID) {
    probing.remove(id)
  }

  /// Not listed, or listed without a session.
  private func isUnheld(_ id: DeviceID) -> Bool {
    guard let entry = entries[id] else { return true }
    if case .held = entry.holding { return false }
    return true
  }

  private static func read(_ session: any DeviceSession) async -> Reading {
    do throws(TransportError) {
      return .state(.ready(try await session.storages()))
    } catch .deviceLocked {
      return .state(.notSharingFiles)
    } catch .deviceDisconnected {
      return .gone
    } catch {
      return .state(.failed(error))
    }
  }

  // MARK: State

  /// Records the entry and emits what changed. Starts or stops the re-check poll in the same
  /// turn, so no observer sees the state without the poll that goes with it.
  private func store(_ info: DeviceInfo, _ state: DeviceState, _ holding: Holding) {
    generations += 1
    let previous = entries[info.id]
    entries[info.id] = Entry(info: info, state: state, holding: holding, generation: generations)
    let device = AttachedDevice(info: info, state: state)
    if previous == nil {
      continuation.yield(.attached(device))
    } else if previous?.state != state {
      continuation.yield(.changed(device))
    }
    updatePolling()
  }
}

// MARK: Polling

extension DeviceHub {
  /// Held devices not sharing files, in serial order.
  fileprivate var waitingIDs: [DeviceID] {
    entries.values.compactMap { entry in
      guard case .held = entry.holding, entry.state == .notSharingFiles else { return nil }
      return entry.info.id
    }.sorted { $0.serial < $1.serial }
  }

  func updatePolling() {
    let waiting = !waitingIDs.isEmpty
    if waiting, poller == nil {
      poller = Task { [weak self, clock] in
        while !Task.isCancelled {
          do {
            try await clock.sleep(for: Self.recheckInterval)
          } catch {
            return
          }
          guard !Task.isCancelled, let self else { return }
          await self.recheckWaiting()
        }
      }
    } else if !waiting, let poller {
      poller.cancel()
      self.poller = nil
    }
  }

  fileprivate func recheckWaiting() async {
    for id in waitingIDs {
      await recheckHeld(id)
    }
  }
}
