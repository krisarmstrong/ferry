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
    case signal(String, RemotePath)
  }

  private(set) var calls: [Call] = []
  private var userEnabled = false
  private var waiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
  private var nextWaiter = 0

  func add(_ spec: DomainSpec) async throws { record(.add(spec)) }
  func disconnect(_ identifier: String) async throws { record(.disconnect(identifier)) }
  func reconnect(_ identifier: String) async throws { record(.reconnect(identifier)) }
  func remove(_ identifier: String) async throws { record(.remove(identifier)) }
  func removeAll() async throws { record(.removeAll) }
  func signal(_ identifier: String, folder: RemotePath) async {
    record(.signal(identifier, folder))
  }
  func isUserEnabled() async -> Bool { userEnabled }

  func setUserEnabled(_ enabled: Bool) {
    userEnabled = enabled
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
      capacity: 1_000_000, free: 900_000)
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

/// A hub, domain controller and request service over a fake transport, with USB ticks under the
/// test's control and a temporary directory standing in for the app-group container.
struct AgentHarness {
  let transport: FakeTransport
  let manager = FakeDomainManager()
  let hub: DeviceHub
  let controller: DomainController
  let service: AgentService
  let container: URL
  private let ticks: AsyncStream<Void>.Continuation
  private let runner: Task<Void, Never>

  init(devices: [FakeDevice] = []) throws {
    transport = FakeTransport(devices: devices)
    let (arrivals, ticks) = AsyncStream.makeStream(of: Void.self)
    self.ticks = ticks
    hub = DeviceHub(transport: transport, arrivals: arrivals, clock: ManualClock())
    controller = DomainController(hub: hub, manager: manager)
    container = FileManager.default.temporaryDirectory.appending(
      path: "ferry-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    service = AgentService(hub: hub, domains: controller, allowedRoot: container)
    runner = Task { [controller] in await controller.run() }
  }

  func tick() {
    ticks.yield()
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

  /// Writes `contents` to a new file in the container.
  func source(_ name: String, _ contents: String) throws -> URL {
    let url = container.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  func finish() {
    ticks.finish()
    runner.cancel()
    try? FileManager.default.removeItem(at: container)
  }
}
