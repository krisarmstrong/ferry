import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation

@testable import FerryAgentCore

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
  DomainNaming.identifier(for: storageID(device, key))
}

func storageID(_ device: FakeDevice, _ key: String = internalKey) -> StorageID {
  StorageID(device: device.info.id, key: key)
}

func path(_ string: String) throws -> RemotePath {
  try RemotePath(string)
}

/// A new folder for item tables, which a test may share between harnesses to restart the agent.
func itemStore() -> URL {
  TestScratch.root.appending(
    path: "ferry-items-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A hub, domain controller and request service over a fake transport, with USB ticks under the
/// test's control and a temporary directory for the files a client would send.
struct AgentHarness {
  let transport: FakeTransport
  /// ADB, when the harness serves both methods through a `CompositeTransport`.
  let adb: FakeTransport?
  let manager: FakeDomainManager
  let hub: DeviceHub
  let controller: DomainController
  let service: AgentService
  let clock = ManualClock()
  /// The controller's own clock, for its retries, apart from the hub's.
  let retryClock = ManualClock()
  let scratch: URL
  let store: URL
  private let ticks: AsyncStream<Void>.Continuation
  private let runner: Task<Void, Never>

  init(
    devices: [FakeDevice] = [], existing: [String] = [], store: URL = itemStore(),
    manager: FakeDomainManager? = nil, adb: FakeTransport? = nil,
    changes: ((DomainController) -> ChangeWatch)? = nil
  ) throws {
    self.store = store
    self.manager = manager ?? FakeDomainManager(existing: existing)
    let mtp = FakeTransport(devices: devices)
    transport = mtp
    self.adb = adb
    let (arrivals, ticks) = AsyncStream.makeStream(of: Void.self)
    self.ticks = ticks
    let served: any DeviceTransport =
      adb.map { CompositeTransport(mtp: mtp, adb: $0) } ?? mtp
    hub = DeviceHub(transport: served, arrivals: arrivals, clock: clock)
    controller = DomainController(
      hub: hub, manager: self.manager, itemStore: store, clock: retryClock)
    scratch = TestScratch.root.appending(
      path: "ferry-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    // The agent's scratch copies go under the test scratch folder, so its size guard covers them.
    service = AgentService(
      hub: hub, domains: controller, scratch: scratch, changes: changes?(controller))
    runner = Task { [controller] in await controller.run() }
  }

  func tick() {
    ticks.yield()
  }

  /// The identifier the domain's table has for `path`, assigning one if it has none.
  func id(_ path: RemotePath, in domain: String) async throws -> ItemID {
    try await controller.items(of: domain).id(for: path)
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
    identifier: DomainNaming.identifier(
      for: StorageID(device: DeviceID(serial: "ZZBARRIER"), key: internalKey)),
    displayName: "Barrier")

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

extension AgentResponse {
  /// Whether the reply carries an item, as a fetch, create or change does.
  var isEntry: Bool {
    if case .entry = self { return true }
    return false
  }
}
