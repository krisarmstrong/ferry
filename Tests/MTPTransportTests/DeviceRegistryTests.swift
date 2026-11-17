import DeviceKit
import Synchronization
import Testing

@testable import MTPTransport

struct DeviceRegistryTests {
  /// A device in these tests is its USB address; its serial is `S<address>`.
  struct Handle: Sendable, Equatable {
    let raw: Int
  }

  /// What the bus holds and what the registry did to it. `attached` is a bitmask of addresses,
  /// atomic because detection is synchronous.
  final class Bus: Sendable {
    let attached = Atomic<UInt64>(0)
    let log = Log()

    init(_ addresses: [Int]) {
      plug(addresses)
    }

    func plug(_ addresses: [Int]) {
      attached.store(addresses.reduce(0) { $0 | 1 << $1 }, ordering: .sequentiallyConsistent)
    }

    var addresses: [Int] {
      let mask = attached.load(ordering: .sequentiallyConsistent)
      return (0..<64).filter { mask & 1 << $0 != 0 }
    }
  }

  actor Log {
    private(set) var opens: [Int: Int] = [:]
    private(set) var closes: [Int: Int] = [:]
    private(set) var peak = 0
    private var active = 0
    /// Addresses another process holds; opening them fails.
    var busy: Set<Int> = []
    /// Address whose device now reports another serial, as after a swap on the same port.
    var swapped: Set<Int> = []

    func setBusy(_ addresses: Set<Int>) { busy = addresses }
    func setSwapped(_ addresses: Set<Int>) { swapped = addresses }

    func open(_ raw: Int) async throws(TransportError) -> Handle {
      active += 1
      peak = max(peak, active)
      for _ in 0..<10 { await Task.yield() }
      active -= 1
      guard !busy.contains(raw) else { throw .deviceBusy }
      opens[raw, default: 0] += 1
      return Handle(raw: raw)
    }

    func close(_ handle: Handle) {
      closes[handle.raw, default: 0] += 1
    }

    func info(_ handle: Handle) -> DeviceInfo {
      let serial = swapped.contains(handle.raw) ? "X\(handle.raw)" : "S\(handle.raw)"
      return DeviceInfo(id: DeviceID(serial: serial), manufacturer: "Acme", model: "Phone")
    }
  }

  static func id(_ raw: Int) -> DeviceID { DeviceID(serial: "S\(raw)") }

  static func info(_ raw: Int) -> DeviceInfo {
    DeviceInfo(id: id(raw), manufacturer: "Acme", model: "Phone")
  }

  static func busyInfo(_ raw: Int) -> DeviceInfo {
    DeviceInfo(id: DeviceID(serial: "usb-1-\(raw)"), manufacturer: "Vendor", model: "Product")
  }

  func makeRegistry(_ bus: Bus) -> DeviceRegistry<Int, Handle> {
    let log = bus.log
    return DeviceRegistry(
      label: "test-registry",
      driver: .init(
        detect: { bus.addresses },
        location: { BusLocation(bus: 1, address: UInt8($0)) },
        describe: { Self.busyInfo($0) },
        open: { raw throws(TransportError) in
          let handle = try await log.open(raw)
          return (handle, await log.info(handle))
        },
        close: { await log.close($0) }))
  }

  @Test func scanOpensEachUnheldDeviceOnceAndClosesIt() async throws {
    let bus = Bus([1, 2, 3])
    let scan = try await makeRegistry(bus).scan()

    #expect(scan == DeviceScan(devices: [1, 2, 3].map(Self.info)))
    #expect(await bus.log.opens == [1: 1, 2: 1, 3: 1])
    #expect(await bus.log.closes == [1: 1, 2: 1, 3: 1])
  }

  @Test func scanNeverOpensHeldDevice() async throws {
    let bus = Bus([1, 2])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))

    for _ in 0..<3 {
      #expect(try await registry.scan() == DeviceScan(devices: [1, 2].map(Self.info)))
    }
    #expect(await bus.log.opens == [1: 2, 2: 4])
  }

  @Test func openOpensOnlyTheChosenDevice() async throws {
    let bus = Bus([1, 2, 3])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()

    let opened = try await registry.open(Self.id(2))

    #expect(opened.device == Handle(raw: 2))
    #expect(await bus.log.opens == [1: 1, 2: 2, 3: 1])
  }

  @Test func heldDeviceIsNotOpenedTwice() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))

    await #expect(throws: TransportError.deviceBusy) {
      _ = try await registry.open(Self.id(1))
    }
    #expect(await bus.log.opens == [1: 2])
  }

  @Test func releaseLetsTheDeviceBeOpenedAgain() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.release(opened.location)

    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))
    #expect(await bus.log.opens == [1: 4])
  }

  @Test func deviceAnotherProcessHoldsIsBusyByLocation() async throws {
    let bus = Bus([1, 2])
    await bus.log.setBusy([2])
    let registry = makeRegistry(bus)

    #expect(
      try await registry.scan() == DeviceScan(devices: [Self.info(1)], busy: [Self.busyInfo(2)]))
    await #expect(throws: TransportError.deviceNotFound(Self.busyInfo(2).id)) {
      _ = try await registry.open(Self.busyInfo(2).id)
    }
  }

  @Test func deviceGoneSinceScanIsNotFound() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    bus.plug([])

    await #expect(throws: TransportError.deviceNotFound(Self.id(1))) {
      _ = try await registry.open(Self.id(1))
    }
  }

  @Test func otherDeviceAtTheSameLocationIsNotFoundAndClosed() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    await bus.log.setSwapped([1])

    await #expect(throws: TransportError.deviceNotFound(Self.id(1))) {
      _ = try await registry.open(Self.id(1))
    }
    #expect(await bus.log.closes == [1: 2])
    #expect(try await registry.scan().devices.map(\.id) == [DeviceID(serial: "X1")])
  }

  @Test func scansAndOpensNeverOverlap() async throws {
    let bus = Bus([1, 2])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()

    async let first = registry.scan()
    async let opened = registry.open(Self.id(1))
    async let second = registry.scan()
    _ = try await (first, opened, second)

    #expect(await bus.log.peak == 1)
  }

  @Test func detectionFailureIsThrown() async {
    let registry = DeviceRegistry<Int, Handle>(
      label: "test-registry",
      driver: .init(
        detect: { () throws(TransportError) in throw .io("usb") },
        location: { BusLocation(bus: 1, address: UInt8($0)) },
        describe: { Self.busyInfo($0) },
        open: { (Handle(raw: $0), Self.info($0)) },
        close: { _ in }))

    await #expect(throws: TransportError.io("usb")) {
      _ = try await registry.scan()
    }
  }
}
