import DeviceKit
import Synchronization
import Testing

@testable import MTPTransport

struct DeviceRegistryTests {
  /// A device in these tests is its USB address; its serial is `S<address>`.
  struct Handle: Sendable, Equatable {
    let raw: Int
  }

  /// What the bus holds and what the registry did to it. A device is its USB address, with the
  /// registry entry of its current enumeration; each `plug` enumerates anew.
  final class Bus: Sendable {
    let attached = Mutex<[Int: USBDeviceRecord]>([:])
    let log = Log()
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

    /// The device at `address` enumerates again, as after a replug or a USB mode switch.
    func reenumerate(_ address: Int) {
      attached.withLock { $0[address] = record(address, vendor: 0x18D1) }
    }

    var devices: [USBDeviceRecord] {
      attached.withLock { $0.values.sorted { $0.address < $1.address } }
    }

    private func record(_ address: Int, vendor: UInt16) -> USBDeviceRecord {
      let interfaces: [USBInterface] =
        vendor == 0x05AC
        ? [
          USBInterface(interfaceClass: 0x06, subclass: 1, interfaceProtocol: 1, endpoints: 3),
          USBInterface(interfaceClass: 0xFF, subclass: 0xFE, interfaceProtocol: 2, endpoints: 3),
        ] : [USBInterface(interfaceClass: 0xFF, subclass: 0xFF, interfaceProtocol: 0, endpoints: 3)]
      return USBDeviceRecord(
        registryID: enumerations.add(1, ordering: .sequentiallyConsistent).newValue,
        locationID: 1 << 24, address: UInt8(address), vendorID: vendor, productID: 0x4EE1,
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
    /// Address whose device now reports another serial, as after a swap on the same port.
    var swapped: Set<Int> = []

    /// Closing resets the device, so it enumerates again, as libmtp's release does to Android.
    var resetsOnClose: Bus?

    func setBusy(_ addresses: Set<Int>) { busy = addresses }
    func setResetsOnClose(_ bus: Bus) { resetsOnClose = bus }
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
      resetsOnClose?.reenumerate(handle.raw)
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
        attached: { bus.devices },
        candidacy: { USBCandidates.candidacy(of: $0, inTable: true) },
        resolve: { record in
          bus.resolves.withLock { $0[Int(record.address), default: 0] += 1 }
          return Int(record.address)
        },
        open: { raw, _ throws(TransportError) in
          let handle = try await log.open(raw)
          return (handle, await log.info(handle))
        },
        close: { await log.close($0) }))
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
        close: { _ in }))

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

  @Test func ejectedDeviceIsNotSharingAndNeverReopened() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)

    for _ in 0..<2 {
      #expect(try await registry.scan() == DeviceScan(devices: [], notSharing: [Self.info(1)]))
    }
    await #expect(throws: TransportError.deviceNotFound(Self.id(1))) {
      _ = try await registry.open(Self.id(1))
    }
    #expect(await bus.log.opens == [1: 1])

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
