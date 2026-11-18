import DeviceKit
import Synchronization
import Testing

@testable import MTPTransport

struct DeviceRegistryTests {
  /// A device in these tests is its USB address; its serial is `S<address>`.
  struct Handle: Sendable, Equatable {
    let raw: Int
  }

  /// What the bus holds and what the registry did to it. A device is the port it is plugged
  /// into, which is its first USB address and names its serial; each `plug` enumerates anew.
  final class Bus: Sendable {
    let attached = Mutex<[Int: USBDeviceRecord]>([:])
    let log = Log()
    let start = ContinuousClock.now
    let elapsed = Mutex<Duration>(.zero)
    /// How often each address was resolved to a raw device, which probes an unlisted one.
    let resolves = Mutex<[Int: Int]>([:])
    private let enumerations = Atomic<UInt64>(0)

    init(_ addresses: [Int]) {
      plug(addresses)
    }

    /// Plugs in each address: an iPhone at an address in `apple`, otherwise an MTP device.
    func plug(_ addresses: [Int], apple: Set<Int> = []) {
      attached.withLock { devices in
        devices = [:]
        for address in addresses {
          devices[address] = record(address, vendor: apple.contains(address) ? 0x05AC : 0x18D1)
        }
      }
    }

    /// The device at `port` enumerates again, as after a replug or a USB mode switch, at
    /// `address` (by default the same one).
    func reenumerate(_ port: Int, at address: Int? = nil, product: UInt16 = 0x4EE1) {
      attached.withLock {
        $0[port] = record(port, address: address, vendor: 0x18D1, product: product)
      }
    }

    func advance(by duration: Duration) {
      elapsed.withLock { $0 += duration }
    }

    var now: ContinuousClock.Instant {
      start.advanced(by: elapsed.withLock { $0 })
    }

    var devices: [USBDeviceRecord] {
      attached.withLock { $0.values.sorted { $0.address < $1.address } }
    }

    private func record(
      _ port: Int, address: Int? = nil, vendor: UInt16, product: UInt16 = 0x4EE1
    ) -> USBDeviceRecord {
      let interfaces: [USBInterface] =
        vendor == 0x05AC
        ? [
          USBInterface(interfaceClass: 0x06, subclass: 1, interfaceProtocol: 1, endpoints: 3),
          USBInterface(interfaceClass: 0xFF, subclass: 0xFE, interfaceProtocol: 2, endpoints: 3),
        ] : [USBInterface(interfaceClass: 0xFF, subclass: 0xFF, interfaceProtocol: 0, endpoints: 3)]
      return USBDeviceRecord(
        registryID: enumerations.add(1, ordering: .sequentiallyConsistent).newValue,
        locationID: 1 << 24 | UInt32(port) << 16, address: UInt8(address ?? port),
        vendorID: vendor, productID: product,
        interfaces: interfaces, vendorName: "Vendor", productName: "Product")
    }
  }

  actor Log {
    private(set) var opens: [Int: Int] = [:]
    private(set) var closes: [Int: Int] = [:]
    private(set) var peak = 0
    private var active = 0
    /// Addresses another process holds; opening them fails.
    var busy: Set<Int> = []

    /// Closing resets the device, so it enumerates again, as libmtp's release does to Android.
    var resetsOnClose: Bus?

    func setBusy(_ addresses: Set<Int>) { busy = addresses }
    func setResetsOnClose(_ bus: Bus) { resetsOnClose = bus }
    /// Ports whose device is the one first seen on another port, moved there.
    var moved: [Int: Int] = [:]
    func setMoved(_ port: Int, from original: Int) { moved[port] = original }

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
      resetsOnClose?.reenumerate(handle.raw)
    }

    func info(_ handle: Handle) -> DeviceInfo {
      DeviceInfo(
        id: DeviceID(serial: "S\(moved[handle.raw] ?? handle.raw)"), manufacturer: "Acme",
        model: "Phone")
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
        attached: { bus.devices },
        candidacy: { USBCandidates.candidacy(of: $0, inTable: true) },
        resolve: { record in
          let port = Int(record.locationID >> 16 & 0xFF)
          bus.resolves.withLock { $0[port, default: 0] += 1 }
          return port
        },
        open: { raw, _ throws(TransportError) in
          let handle = try await log.open(raw)
          return (handle, await log.info(handle))
        },
        close: { await log.close($0) },
        now: { bus.now }))
  }

  @Test func scanOpensEachUnheldDeviceOnceAndKeepsIt() async throws {
    let bus = Bus([1, 2, 3])
    let registry = makeRegistry(bus)
    for _ in 0..<2 {
      #expect(try await registry.scan() == DeviceScan(devices: [1, 2, 3].map(Self.info)))
    }
    #expect(await bus.log.opens == [1: 1, 2: 1, 3: 1])
    #expect(await bus.log.closes == [:])
  }

  @Test func keptDeviceThatLeavesIsClosedByTheNextScan() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    bus.plug([])
    #expect(try await registry.scan() == DeviceScan(devices: []))
    #expect(await bus.log.closes == [1: 1])
  }

  @Test func scanNeverOpensHeldDevice() async throws {
    let bus = Bus([1, 2])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))

    for _ in 0..<3 {
      #expect(try await registry.scan() == DeviceScan(devices: [1, 2].map(Self.info)))
    }
    #expect(await bus.log.opens == [1: 1, 2: 1])
  }

  @Test func openHandsOverOnlyTheChosenDevice() async throws {
    let bus = Bus([1, 2, 3])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()

    let opened = try await registry.open(Self.id(2))

    #expect(opened.device == Handle(raw: 2))
    #expect(await bus.log.opens == [1: 1, 2: 1, 3: 1])
  }

  @Test func heldDeviceIsNotOpenedTwice() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))

    await #expect(throws: TransportError.deviceBusy) {
      _ = try await registry.open(Self.id(1))
    }
    #expect(await bus.log.opens == [1: 1])
  }

  @Test func releaseLetsTheDeviceBeOpenedAgain() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.release(opened.location)

    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))
    #expect(await bus.log.opens == [1: 2])
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
        attached: { () throws(TransportError) in throw .io("usb") },
        candidacy: { _ in .mtp },
        resolve: { Int($0.address) },
        open: { raw, _ in (Handle(raw: raw), Self.info(raw)) },
        close: { _ in },
        now: { ContinuousClock.now }))

    await #expect(throws: TransportError.io("usb")) {
      _ = try await registry.scan()
    }
  }
}

extension DeviceRegistryTests {
  // MARK: Candidates, parking, re-enumeration, hand-over

  @Test func deniedDeviceIsNeitherOpenedNorReported() async throws {
    let bus = Bus([])
    bus.plug([1, 2], apple: [2])
    let registry = makeRegistry(bus)

    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
    #expect(await bus.log.opens == [1: 1])
    #expect(await bus.log.closes == [:])
  }

  @Test func busyDeviceIsParkedAndNotReopenedUntilRechecked() async throws {
    let bus = Bus([1])
    await bus.log.setBusy([1])
    let registry = makeRegistry(bus)
    let busy = DeviceScan(devices: [], busy: [Self.busyInfo(1)])
    #expect(try await registry.scan() == busy)
    await bus.log.setBusy([])

    #expect(try await registry.scan() == busy)
    #expect(try await registry.scan() == busy)
    #expect(await bus.log.opens == [:])

    await registry.unpark(Self.busyInfo(1).id)
    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
    #expect(await bus.log.opens == [1: 1])
  }

  @Test func busyDeviceIsTriedAgainOnceReplugged() async throws {
    let bus = Bus([1])
    await bus.log.setBusy([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    await bus.log.setBusy([])

    bus.reenumerate(1)
    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
  }

  /// A replug, or a switch from charging to file transfer, can come back at the same address.
  /// The held record is for the old enumeration, so the new one is opened, not taken as held.
  @Test func reenumeratedDeviceAtTheSameAddressIsNotTheHeldOne() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    _ = try await registry.open(Self.id(1))

    bus.reenumerate(1)
    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
    #expect(await bus.log.opens == [1: 2])
  }

  @Test func candidateIsResolvedOncePerEnumeration() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    for _ in 0..<3 { _ = try await registry.scan() }
    #expect(bus.resolves.withLock { $0 } == [1: 1])
  }

  /// libmtp's release resets an Android device, which then enumerates anew: a scan that opened
  /// and closed it to read its serial would leave `open` nothing to open. The scan's handle is
  /// kept and handed over instead.
  @Test func scannedDeviceIsHandedToOpenWithoutAnotherOpen() async throws {
    let bus = Bus([1])
    await bus.log.setResetsOnClose(bus)
    let registry = makeRegistry(bus)
    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))

    let opened = try await registry.open(Self.id(1))

    #expect(opened.device == Handle(raw: 1))
    #expect(await bus.log.opens == [1: 1])
    #expect(await bus.log.closes == [:])
  }
}
