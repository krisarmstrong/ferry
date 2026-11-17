import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DeviceHub")

public enum HubEvent: Sendable, Equatable {
  /// A device the hub had not listed. Emitted once per device until it is detached.
  case attached(AttachedDevice)
  case changed(AttachedDevice)
  case detached(DeviceID)
}

/// The one owner of every open device session in the agent.
///
/// Each USB tick on `arrivals` makes the hub list the attached devices, open the new ones, and
/// ask each held session for its storages. A held device's departure is learned only from its
/// own session reporting `.deviceDisconnected`: a transport cannot list a device this process
/// already holds open, so absence from the list says nothing about it.
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
  private let clock: any Clock<Duration>
  private var entries: [DeviceID: Entry] = [:]
  private var generations: UInt64 = 0
  /// Held devices with a tick's storage read still in flight.
  private var probing: Set<DeviceID> = []
  /// The reconcile most recently asked for; the next one waits for it.
  private var lastReconcile: Task<Void, Never>?
  private var poller: Task<Void, Never>?

  var isRechecking: Bool { poller != nil }

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
      for await _ in arrivals {
        guard let self else { return }
        await self.reconcile()
      }
    }
  }

  deinit {
    continuation.finish()
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

  /// Re-reads a held device's storages, for instance after file transfer was turned on.
  public func recheck(_ id: DeviceID) async {
    guard let entry = entries[id], case .held(let session) = entry.holding else { return }
    let reading = await Self.read(session)
    guard let current = entries[id], current.generation == entry.generation else { return }
    switch reading {
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

  /// Closes the device's session. It stays listed as `.notSharingFiles` until it is unplugged.
  public func eject(_ id: DeviceID) async {
    guard let entry = entries[id], case .held(let session) = entry.holding else { return }
    store(entry.info, .notSharingFiles, .unheld)
    await session.close()
    log.info("device \(id.serial, privacy: .private) ejected")
  }

  // MARK: Reconcile

  /// Reconciles run one at a time, in the order they were asked for.
  private func reconcile() async {
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
    let listed: [DeviceInfo]
    do throws(TransportError) {
      listed = try await transport.connectedDevices()
    } catch .deviceBusy {
      // Every attached device is open somewhere, ours included.
      listed = []
    } catch {
      log.error("listing devices failed: \(String(describing: error), privacy: .public)")
      return
    }
    let present = Set(listed.map(\.id))
    for (id, entry) in entries where !present.contains(id) {
      guard case .unheld = entry.holding else { continue }
      entries[id] = nil
      log.info("device \(id.serial, privacy: .private) detached")
      continuation.yield(.detached(id))
    }
    for info in listed {
      await admit(info)
    }
  }

  /// Opens a device the hub does not list yet, or retries one that was busy or failed to open.
  private func admit(_ info: DeviceInfo) async {
    let existing = entries[info.id]
    if let existing {
      guard case .unheld = existing.holding else { return }
      switch existing.state {
      case .busy, .failed: break
      case .ready, .notSharingFiles: return
      }
    }
    let generation = existing?.generation
    let session: any DeviceSession
    do throws(TransportError) {
      session = try await transport.open(info.id)
    } catch .deviceNotFound {
      return
    } catch {
      guard entries[info.id]?.generation == generation else { return }
      store(info, error == .deviceBusy ? .busy : .failed(error), .unheld)
      return
    }
    let reading = await Self.read(session)
    guard entries[info.id]?.generation == generation, case .state(let state) = reading else {
      await session.close()
      return
    }
    log.info("device \(info.id.serial, privacy: .private) opened")
    store(info, state, .held(session))
  }

  /// Reads a held device's storages off this tick, so a long transfer queued on its session
  /// does not hold up other devices.
  private func probe(_ id: DeviceID) {
    guard probing.insert(id).inserted else { return }
    Task { [weak self] in
      await self?.recheck(id)
      await self?.probed(id)
    }
  }

  private func probed(_ id: DeviceID) {
    probing.remove(id)
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

  private var waitingIDs: [DeviceID] {
    entries.values.compactMap { entry in
      guard case .held = entry.holding, entry.state == .notSharingFiles else { return nil }
      return entry.info.id
    }
  }

  private func updatePolling() {
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

  private func recheckWaiting() async {
    for id in waitingIDs {
      await recheck(id)
    }
  }
}
