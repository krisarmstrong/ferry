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
/// closed, so a later scan can open it afresh, after a back-off. An ejected device is listed as
/// `.ejected` while the transport reports it so; any other device a scan reports as usable and
/// the hub does not hold is opened.
///
/// A device that is attached but not sharing files is re-checked every two seconds. MTP has no
/// event for "file transfer turned on", so this is the hub's one poll, and it runs only while
/// such a device is held.
///
/// A device reachable more than one way is served by the method the transport reports for it.
/// When that changes for a held device (ADB authorised, revoked, or the cable pulled while the
/// network stays), the hub replaces its session in place: the device keeps its entry, and so its
/// domains and item identities, and the change is reported with the new method. The swap waits
/// until no request holds a lease on the device (see `lease(_:)`); requests that ask meanwhile
/// wait for the new session, so two sessions never serve one device at once. An MTP session
/// that ADB replaces is kept open, idle: releasing it resets an Android device, and the reset
/// would drop the ADB route that replaced it. It serves again if ADB goes, and is closed when the
/// device is ejected or leaves.
public actor DeviceHub {
  enum Holding {
    case held(any DeviceSession)
    /// No session open: ejected, held by another app, or failed to open.
    case unheld
  }

  struct Entry {
    var info: DeviceInfo
    var state: DeviceState
    var method: ConnectionMethod
    var holding: Holding
    /// Renewed on every store, so a result read across a suspension is dropped once the entry
    /// it was read for has been replaced, ejected or removed.
    var generation: UInt64
  }

  enum Reading {
    case state(DeviceState)
    case gone
  }

  static let recheckInterval = Duration.seconds(2)

  /// Device changes, in order. Single consumer: iterate it from one task only, since an
  /// `AsyncStream` hands each event to just one of its iterators.
  public nonisolated let events: AsyncStream<HubEvent>
  let continuation: AsyncStream<HubEvent>.Continuation
  let transport: any DeviceTransport
  let clock: any Clock<Duration>
  var entries: [DeviceID: Entry] = [:]
  /// Devices the user ejected, never opened while listed. The transport is the authority: it
  /// reports them in `DeviceScan.ejected`, through the resets their close causes, until they
  /// count as unplugged; once it offers one as usable instead, the hub drops it from here. The
  /// hub's own entry covers the moment of the eject, before the transport has been told, and is
  /// cleared by the user's Mount (`recheck`) or when no list of a scan names the device.
  var ejected: Set<DeviceID> = []
  /// Devices whose eject is under way: ejected before the transport has been told.
  var ejecting: Set<DeviceID> = []
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
  var poller: Task<Void, Never>?

  var isRechecking: Bool { poller != nil }

  /// Network devices waiting for the user to allow this Mac, from the most recent scan.
  var awaiting: [String] = []
  /// MTP sessions kept open, idle, while ADB serves their device.
  var kept: [DeviceID: any DeviceSession] = [:]
  /// Leases handed out and not yet released, by device.
  var leases: [DeviceID: Int] = [:]
  /// Swaps and ejects waiting for their device's leases to be released.
  var drainWaiters: [DeviceID: [CheckedContinuation<Void, Never>]] = [:]
  /// Devices whose session is being replaced.
  var swapping: Set<DeviceID> = []
  /// Leases and ejects waiting for a swap to finish, by device.
  var swapWaiters: [DeviceID: [CheckedContinuation<Void, Never>]] = [:]

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
    entries.values.map { AttachedDevice(info: $0.info, state: $0.state, method: $0.method) }
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

  /// Re-reads a held device's storages. The hub's own probes and polls use this, never
  /// `recheck`, so a device ejected while they run is never offered to the transport again.
  func recheckHeld(_ id: DeviceID) async {
    guard !swapping.contains(id), let entry = entries[id], case .held(let session) = entry.holding
    else { return }
    let reading = await Self.read(session)
    guard !swapping.contains(id), let current = entries[id],
      current.generation == entry.generation
    else { return }
    switch reading {
    case .state(.failed(let error)):
      // Let the session go, so a later scan can open the device afresh.
      await session.close()
      guard let latest = entries[id], latest.generation == current.generation else { return }
      if await resumeKept(latest.info, generation: latest.generation) { return }
      store(latest.info, .failed(error), .unheld, method: latest.method)
      backOff(id)
    case .state(let state):
      store(current.info, state, current.holding, method: current.method)
    case .gone:
      // Closed while still listed as held, so a replug of the same device ticked meanwhile is
      // not admitted, and reported, ahead of this departure.
      await session.close()
      guard let latest = entries[id], latest.generation == current.generation else { return }
      if await resumeKept(latest.info, generation: latest.generation) { return }
      drop(id)
    }
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
    for (id, entry) in entries where !swapping.contains(id) {
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
    awaiting = scan.awaitingAuthorization
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
      store(info, .busy, .unheld, method: scan.method(of: info.id))
    }
    for info in scan.notSharing where isUnheld(info.id) {
      store(info, .notSharingFiles, .unheld, method: scan.method(of: info.id))
    }
    // The transport decides when an ejected device stops being ejected (unplugged long enough,
    // or found where it could be opened): the hub follows, except mid-eject.
    let stillEjected = Set(scan.ejected.map(\.id))
    for info in scan.devices
    where !stillEjected.contains(info.id) && !ejecting.contains(info.id) {
      ejected.remove(info.id)
    }
    for info in scan.ejected where isUnheld(info.id) {
      ejected.insert(info.id)
      store(info, .ejected, .unheld, method: scan.method(of: info.id))
    }
    await serve(scan)
  }

  /// Opens each usable device the hub does not hold, and moves each held one whose method the
  /// scan says has changed.
  private func serve(_ scan: DeviceScan) async {
    for info in scan.devices where !swapping.contains(info.id) {
      let method = scan.method(of: info.id)
      if let entry = entries[info.id], case .held = entry.holding {
        if entry.method != method { beginSwap(info.id, to: method) }
      } else {
        await admit(info, method: method)
      }
    }
  }

  /// Opens a device the hub does not hold: one it does not list yet, or one that was busy,
  /// failed, not sharing files or ejected and is now offered as usable.
  private func admit(_ info: DeviceInfo, method: ConnectionMethod) async {
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
      store(info, error == .deviceBusy ? .busy : .failed(error), .unheld, method: method)
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
      store(info, state, .unheld, method: method)
      backOff(info.id)
      return
    }
    backoff[info.id] = nil
    let opened = await session.method
    log.info(
      "device \(info.id.serial, privacy: .private) opened over \(opened.rawValue, privacy: .public)"
    )
    store(info, state, .held(session), method: opened)
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

  static func read(_ session: any DeviceSession) async -> Reading {
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
  func store(
    _ info: DeviceInfo, _ state: DeviceState, _ holding: Holding, method: ConnectionMethod
  ) {
    generations += 1
    let previous = entries[info.id]
    entries[info.id] = Entry(
      info: info, state: state, method: method, holding: holding, generation: generations)
    let device = AttachedDevice(info: info, state: state, method: method)
    if let previous {
      let before = AttachedDevice(
        info: previous.info, state: previous.state, method: previous.method)
      if before != device { continuation.yield(.changed(device)) }
    } else {
      continuation.yield(.attached(device))
    }
    updatePolling()
  }
}
