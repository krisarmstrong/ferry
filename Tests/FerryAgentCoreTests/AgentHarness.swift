import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation

@testable import FerryAgentCore

/// Records every call, so a test can wait for the controller to act on a hub event.
actor FakeDomainManager: DomainManaging {
  enum Call: Equatable, Sendable {
    case add(DomainSpec)
    case disconnect(String)
    case reconnect(String)
    case remove(String)
    case removeAll
    case signal(String)
  }

  private(set) var calls: [Call] = []
  private let preexisting: [String]
  /// Set by `holdExisting()`: `existing()` waits until `releaseExisting()`.
  private var existingHeld = false
  private var existingWaiter: CheckedContinuation<Void, Never>?
  private var userEnabled = false
  /// Where removing each domain saves its unsent changes.
  private var preserved: [String: URL] = [:]
  private var waiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
  private var nextWaiter = 0

  /// `existing` are the domains the system already has, as after an agent restart.
  init(existing: [String] = []) {
    preexisting = existing
  }

  func add(_ spec: DomainSpec) async throws { record(.add(spec)) }
  func disconnect(_ identifier: String) async throws { record(.disconnect(identifier)) }
  func reconnect(_ identifier: String) async throws { record(.reconnect(identifier)) }
  func remove(_ identifier: String) async throws -> URL? {
    record(.remove(identifier))
    return preserved[identifier]
  }
  func removeAll() async throws -> [URL] {
    record(.removeAll)
    return preserved.keys.sorted().compactMap { preserved[$0] }
  }
  func signal(_ identifier: String) async {
    record(.signal(identifier))
  }
  func isUserEnabled() async -> Bool { userEnabled }
  func existing() async throws -> [String] {
    if existingHeld {
      await withCheckedContinuation { existingWaiter = $0 }
    }
    return preexisting
  }

  /// Makes `existing()` wait, as listing the system's domains can take a while after a restart.
  func holdExisting() {
    existingHeld = true
  }

  func releaseExisting() {
    existingHeld = false
    existingWaiter?.resume()
    existingWaiter = nil
  }

  func setUserEnabled(_ enabled: Bool) {
    userEnabled = enabled
  }

  /// Removing `identifier` saves unsent changes to `location`.
  func preserve(_ identifier: String, at location: URL) {
    preserved[identifier] = location
  }

  /// Returns every call so far, once there are at least `count` or the test is cancelled, as
  /// its time limit does, so a missing call fails the test instead of hanging it.
  func waitForCalls(_ count: Int) async -> [Call] {
    guard calls.count < count, !Task.isCancelled else { return calls }
    nextWaiter += 1
    let id = nextWaiter
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before registering: the handler's release has nothing to resume.
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters[id] = (count, continuation)
        }
      }
    } onCancel: {
      Task { await self.release(id) }
    }
    return calls
  }

  private func release(_ id: Int) {
    waiters.removeValue(forKey: id)?.continuation.resume()
  }

  private func record(_ call: Call) {
    calls.append(call)
    for (id, waiter) in waiters where waiter.count <= calls.count {
      release(id)
    }
  }
}

let internalKey = "Internal|vol0"
let cardKey = "SD card|vol1"

func makeDevice(
  _ serial: String, model: String = "Phone", keys: [String] = [internalKey], locked: Bool = false
) async -> FakeDevice {
  let id = DeviceID(serial: serial)
  let storages = keys.map { key in
    StorageInfo(
      id: StorageID(device: id, key: key), description: String(key.prefix { $0 != "|" }),
      capacity: 1 << 30, free: 1 << 29)
  }
  let device = FakeDevice(
    info: DeviceInfo(id: id, manufacturer: "Fake", model: model), storages: storages)
  await device.setLocked(locked)
  return device
}

func domainID(_ device: FakeDevice, _ key: String = internalKey) -> String {
  "\(device.info.id.serial)|\(key)"
}

func storageID(_ device: FakeDevice, _ key: String = internalKey) -> StorageID {
  StorageID(device: device.info.id, key: key)
}

func path(_ string: String) throws -> RemotePath {
  try RemotePath(string)
}

/// A new folder for item tables, which a test may share between harnesses to restart the agent.
func itemStore() -> URL {
  FileManager.default.temporaryDirectory.appending(
    path: "ferry-items-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A hub, domain controller and request service over a fake transport, with USB ticks under the
/// test's control and a temporary directory for the files a client would send.
struct AgentHarness {
  let transport: FakeTransport
  let manager: FakeDomainManager
  let hub: DeviceHub
  let controller: DomainController
  let service: AgentService
  let clock = ManualClock()
  let scratch: URL
  let store: URL
  private let ticks: AsyncStream<Void>.Continuation
  private let runner: Task<Void, Never>

  init(
    devices: [FakeDevice] = [], existing: [String] = [], store: URL = itemStore(),
    manager: FakeDomainManager? = nil
  ) throws {
    self.store = store
    self.manager = manager ?? FakeDomainManager(existing: existing)
    transport = FakeTransport(devices: devices)
    let (arrivals, ticks) = AsyncStream.makeStream(of: Void.self)
    self.ticks = ticks
    hub = DeviceHub(transport: transport, arrivals: arrivals, clock: clock)
    controller = DomainController(hub: hub, manager: self.manager, itemStore: store)
    scratch = FileManager.default.temporaryDirectory.appending(
      path: "ferry-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    service = AgentService(hub: hub, domains: controller)
    runner = Task { [controller] in await controller.run() }
  }

  func tick() {
    ticks.yield()
  }

  /// The identifier the domain's table has for `path`, assigning one if it has none.
  func id(_ path: RemotePath, in domain: String) async throws -> ItemID {
    try await controller.route(domain).items.id(for: path)
  }

  /// Plugs in a ready device of another model and returns every manager call once its domain is
  /// added. The controller handles events in order, so nothing earlier is still pending.
  func barrier(after count: Int) async -> [FakeDomainManager.Call] {
    let other = await makeDevice("ZZBARRIER", model: "Barrier")
    await transport.attach(other)
    tick()
    return await manager.waitForCalls(count + 1)
  }

  static let barrierSpec = DomainSpec(
    identifier: "ZZBARRIER|\(internalKey)", displayName: "Barrier")

  /// Writes `contents` to a new file in the scratch folder.
  func file(_ name: String, _ contents: String) throws -> URL {
    let url = scratch.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// A file holding `contents`, open for reading with its offset at the end, so a reader that
  /// trusted the offset would read nothing.
  func readable(_ name: String, _ contents: String) throws -> FileHandle {
    let handle = try FileHandle(forReadingFrom: file(name, contents))
    try handle.seekToEnd()
    return handle
  }

  /// A file holding `contents`, open for writing.
  func writable(_ name: String, _ contents: String) throws -> (URL, FileHandle) {
    let url = try file(name, contents)
    return (url, try FileHandle(forWritingTo: url))
  }

  /// Stops the harness. `keepingStore` leaves the item tables for a harness that restarts.
  func finish(keepingStore: Bool = false) {
    ticks.finish()
    runner.cancel()
    try? FileManager.default.removeItem(at: scratch)
    if !keepingStore {
      try? FileManager.default.removeItem(at: store)
    }
  }
}
