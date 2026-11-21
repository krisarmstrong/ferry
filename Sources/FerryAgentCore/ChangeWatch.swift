import DeviceKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ChangeWatch")

/// Finds changes made on a device without the user asking (spec "Change detection").
///
/// Each device keeps the 32 folders clients listed most recently. The device watches them, if
/// its session can (ADB's `inotifyd`), and a folder it reports is listed again at once. The
/// reports are hints, and shared storage misses some, so every 30 s the folders are listed again
/// anyway. Each listing records what differs in the domain's change log, and the domain is
/// signalled only then. Nothing is listed while a transfer runs on the device (a hint waits for
/// the next pass that finds none), nor while the Mac sleeps. A watch that ends is started again
/// by the next pass or listing, so a device whose watcher exits at once is tried every 30 s, not
/// in a loop.
///
/// The 30 s relisting runs only while a Ferry location on the device is in use: a client
/// request on one of its domains (Finder listing a folder, reading an item, opening, copying,
/// renaming or deleting) in the last `idlePasses` passes, about 10 minutes. After that only the
/// device's hints list anything, until the next request; a device that has just connected, or
/// an agent that has just started, counts as in use. The signal is the extension's own requests
/// rather than FileProvider's change enumeration, which follows every signal the relisting
/// sends and so would keep a busy device listed for ever (audit M3).
public actor ChangeWatch {
  public static let interval = Duration.seconds(30)
  public static let folderLimit = 32
  /// Passes without a request on the device after which the periodic relisting stops.
  public static let idlePasses = 20
  /// How long hints are gathered before their folders are listed: a burst (Ferry's own delete
  /// of many files, which the device reports one by one) costs one listing.
  static let hintWindow = Duration.seconds(1)

  /// A folder a client listed, in its domain.
  private struct Listed: Equatable {
    let domain: String
    let hint: FolderHint
  }

  private struct Watch {
    let token: UUID
    let folders: [FolderHint]
    let task: Task<Void, Never>
    var ended = false
  }

  let domains: DomainController
  let busy: @Sendable (DeviceID) async -> Bool
  /// A wait on the clock that ends `delay` after the moment it is made, however late it starts:
  /// a timer made when a hint arrives still ends on time.
  let timer: @Sendable (_ delay: Duration) -> @Sendable () async throws -> Void
  let sleeps: AsyncStream<Bool>
  /// Oldest first.
  private var recent: [DeviceID: [Listed]] = [:]
  private var watches: [DeviceID: Watch] = [:]
  /// Hints not acted on yet: a transfer was running, or a listing was under way.
  private var pending: [DeviceID: Set<FolderHint>] = [:]
  private var draining: Set<DeviceID> = []
  /// Passes since a client last used each device's locations.
  private var idle: [DeviceID: Int] = [:]
  private var asleep = false
  /// Passes finished, hints taken in, hint windows closed, and watches ended, for tests to
  /// wait on.
  private(set) var ticks = 0
  private(set) var hintsReceived = 0
  private(set) var hintWindows = 0
  private(set) var endedWatches = 0
  private var waiters: [Int: (ready: () -> Bool, continuation: CheckedContinuation<Void, Never>)] =
    [:]
  private var nextWaiter = 0

  /// `sleeps` says `true` when the Mac goes to sleep and `false` when it wakes.
  public init(
    domains: DomainController, transfers: TransferBoard,
    clock: some Clock<Duration>, sleeps: AsyncStream<Bool>
  ) {
    self.init(
      domains: domains, busy: { await transfers.isBusy($0) }, clock: clock, sleeps: sleeps)
  }

  init(
    domains: DomainController, busy: @escaping @Sendable (DeviceID) async -> Bool,
    clock: some Clock<Duration>, sleeps: AsyncStream<Bool>
  ) {
    self.domains = domains
    self.busy = busy
    timer = { delay in
      let deadline = clock.now.advanced(by: delay)
      return { try await clock.sleep(until: deadline, tolerance: nil) }
    }
    self.sleeps = sleeps
  }

  /// Lists the folders again every `interval` until the calling task is cancelled. Call it once,
  /// from a task that belongs to no request (`requestFreeTask`).
  public func run() async {
    let follower = requestFreeTask { [weak self, sleeps] in
      for await asleep in sleeps { await self?.setAsleep(asleep) }
    }
    defer { follower.cancel() }
    while !Task.isCancelled {
      do {
        try await timer(Self.interval)()
      } catch {
        return
      }
      await pass()
    }
  }

  /// A client used one of the device's locations: the periodic relisting runs for it again.
  func used(_ device: DeviceID) {
    idle[device] = 0
  }

  /// A client listed `folder` of `domain`: it becomes the device's newest watched folder.
  func listed(_ folder: RemotePath, in domain: String) async {
    guard let storage = await domains.connectedStorage(of: domain) else { return }
    used(storage.device)
    let entry = Listed(domain: domain, hint: FolderHint(storage: storage, folder: folder))
    var list = recent[storage.device, default: []]
    list.removeAll { $0 == entry }
    list.append(entry)
    list.removeFirst(max(0, list.count - Self.folderLimit))
    recent[storage.device] = list
    await rewatch(storage.device)
  }

  // MARK: Passes

  private func pass() async {
    defer {
      ticks += 1
      resumeWaiters()
    }
    guard !asleep else { return }
    let connected = await domains.connectedDevices()
    // A device that went away is forgotten: when it comes back its domains know the folders
    // clients listed, and the set is filled from those.
    for device in Set(recent.keys).union(watches.keys).subtracting(connected) {
      forget(device)
    }
    for device in connected.sorted(by: { $0.serial < $1.serial }) {
      let folders = await watched(device)
      guard !folders.isEmpty else {
        stopWatch(device)
        continue
      }
      guard await !busy(device) else { continue }
      let passes = idle[device, default: 0]
      idle[device] = passes + 1
      let hinted = pending.removeValue(forKey: device) ?? []
      let due = passes < Self.idlePasses ? Set(folders.map(\.hint)).union(hinted) : hinted
      if !due.isEmpty { await relist(Array(due), of: device) }
      await rewatch(device)
    }
  }

  /// The device's recent folders whose domain is connected and that it still has. One the
  /// device no longer has is dropped; one whose domain is away (another storage, unmounted) is
  /// kept for its return.
  private func live(_ device: DeviceID) async -> [Listed] {
    var live: [Listed] = []
    var gone: [Listed] = []
    for entry in recent[device] ?? [] {
      guard await domains.connectedStorage(of: entry.domain) == entry.hint.storage else {
        continue
      }
      if await domains.knows(entry.hint.folder, in: entry.domain) {
        live.append(entry)
      } else {
        gone.append(entry)
      }
    }
    recent[device]?.removeAll { gone.contains($0) }
    return live
  }

  /// The device's live recent folders, then, while there is room, the folders its connected
  /// domains know clients listed: after an agent restart no client has listed anything yet, and
  /// Finder lists a folder it already holds only when the system asks it to.
  private func watched(_ device: DeviceID) async -> [Listed] {
    var folders = await live(device)
    for domain in await domains.connectedDomains(of: device) {
      guard let storage = await domains.connectedStorage(of: domain) else { continue }
      for folder in await domains.knownFolders(of: domain) {
        guard folders.count < Self.folderLimit else { return folders }
        let entry = Listed(domain: domain, hint: FolderHint(storage: storage, folder: folder))
        if !folders.contains(entry) { folders.insert(entry, at: 0) }
      }
    }
    return folders
  }

  /// Lists the folders again, each in the domain its storage is connected as.
  private func relist(_ folders: [FolderHint], of device: DeviceID) async {
    for (storage, hints) in Dictionary(grouping: folders, by: \.storage) {
      guard let domain = await domains.connectedDomain(of: storage) else { continue }
      await domains.relistAndSignal(hints.map(\.folder), in: domain)
    }
  }

  // MARK: Watches

  /// Starts the device's watch over its live recent folders, unless one already runs over the
  /// same folders.
  private func rewatch(_ device: DeviceID) async {
    let folders = await watched(device).map(\.hint)
    if let watch = watches[device], !watch.ended, Set(watch.folders) == Set(folders) { return }
    stopWatch(device)
    guard !folders.isEmpty else { return }
    let token = UUID()
    let task = requestFreeTask { [weak self] in
      _ = await self?.follow(device, folders, token: token)
    }
    watches[device] = Watch(token: token, folders: folders, task: task)
  }

  private func forget(_ device: DeviceID) {
    stopWatch(device)
    recent[device] = nil
    pending[device] = nil
    idle[device] = nil
  }

  private func stopWatch(_ device: DeviceID) {
    watches.removeValue(forKey: device)?.task.cancel()
  }

  /// Opens the watch on the device's current session and takes in its hints until it ends.
  private func follow(_ device: DeviceID, _ folders: [FolderHint], token: UUID) async {
    var stream: AsyncStream<FolderHint>?
    do throws(TransportError) {
      let lease = try await domains.leaseSession(of: device)
      stream = await lease.session.watch(folders)
      await domains.hub.release(lease)
    } catch {
      log.info(
        "no session to watch \(device.serial, privacy: .private): \(String(describing: error), privacy: .private)"
      )
    }
    if let stream {
      for await hint in stream { hinted(device, hint) }
    }
    guard watches[device]?.token == token, !Task.isCancelled else { return }
    watches[device]?.ended = true
    endedWatches += 1
    resumeWaiters()
  }

  /// Takes in a hint at once, so the watch is never held up: the first of a burst opens the
  /// device's window, on a task of its own, and the rest join it.
  private func hinted(_ device: DeviceID, _ hint: FolderHint) {
    pending[device, default: []].insert(hint)
    if draining.insert(device).inserted {
      // The window starts now, whenever its task first runs.
      let window = timer(Self.hintWindow)
      requestFreeTask { [weak self] in await self?.drain(device, after: window) }
    }
    hintsReceived += 1
    resumeWaiters()
  }

  /// Lists the folders hinted once the window closes, unless a transfer runs or the Mac sleeps:
  /// they then wait for the next pass. Hints that arrived during the listing open a new window.
  private func drain(_ device: DeviceID, after window: @Sendable () async throws -> Void) async {
    var window = window
    while true {
      do {
        try await window()
      } catch {
        draining.remove(device)
        return
      }
      if !asleep, await !busy(device), let batch = pending.removeValue(forKey: device) {
        await relist(Array(batch), of: device)
      }
      hintWindows += 1
      resumeWaiters()
      guard pending[device]?.isEmpty == false, !asleep, await !busy(device) else {
        draining.remove(device)
        return
      }
      window = timer(Self.hintWindow)
    }
  }

  private func setAsleep(_ asleep: Bool) {
    self.asleep = asleep
    resumeWaiters()
  }

  // MARK: Waiting, for tests

  func rememberedFolders(of device: DeviceID) -> Int { recent[device]?.count ?? 0 }
  func waitForTicks(_ count: Int) async { await waitUntil { self.ticks >= count } }
  func waitForHints(_ count: Int) async { await waitUntil { self.hintsReceived >= count } }
  func waitForHintWindows(_ count: Int) async { await waitUntil { self.hintWindows >= count } }
  func waitForEndedWatches(_ count: Int) async { await waitUntil { self.endedWatches >= count } }
  func waitForSleepState(_ asleep: Bool) async { await waitUntil { self.asleep == asleep } }

  /// Returns once `ready` holds, or the calling task is cancelled, as a test's time limit does.
  private func waitUntil(_ ready: @escaping () -> Bool) async {
    guard !ready() else { return }
    nextWaiter += 1
    let id = nextWaiter
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters[id] = (ready, continuation)
        }
      }
    } onCancel: {
      Task { await self.stopWaiting(id) }
    }
  }

  private func stopWaiting(_ id: Int) {
    waiters.removeValue(forKey: id)?.continuation.resume()
  }

  private func resumeWaiters() {
    for (id, waiter) in waiters where waiter.ready() {
      waiters[id] = nil
      waiter.continuation.resume()
    }
  }
}
