import DeviceKit
import Testing

@testable import MTPTransport

/// An ejected device stays ejected through its own resets until it is unplugged or unparked.
extension DeviceRegistryTests {
  @Test func ejectedDeviceIsNotSharingAndNeverReopened() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)

    for _ in 0..<2 {
      #expect(try await registry.scan() == DeviceScan(devices: [], ejected: [Self.info(1)]))
    }
    await #expect(throws: TransportError.deviceNotFound(Self.id(1))) {
      _ = try await registry.open(Self.id(1))
    }
    #expect(await bus.log.opens == [1: 1])
  }

  /// libmtp's release resets an Android device, so an eject is followed by a new enumeration of
  /// it, on the same port and often at another address. It stays ejected.
  @Test(arguments: [false, true])
  func ejectedDeviceStaysEjectedAcrossItsOwnReset(seenAbsent: Bool) async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)
    if seenAbsent {
      bus.plug([])
      _ = try await registry.scan()
      bus.advance(by: .milliseconds(10))
    }

    bus.reenumerate(1, at: 12)

    #expect(try await registry.scan() == DeviceScan(devices: [], ejected: [Self.info(1)]))
    #expect(await bus.log.opens == [1: 1])
  }

  /// The reset can bring it back with another product ID; it is still the ejected device and is
  /// not opened, so Eject leaves it released.
  @Test func ejectedDeviceBackWithAnotherProductIsNotOpened() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)

    bus.reenumerate(1, at: 12, product: 0x4EE2)

    #expect(try await registry.scan() == DeviceScan(devices: [], ejected: [Self.info(1)]))
    #expect(await bus.log.opens == [1: 1])
    #expect(await bus.log.closes == [:])
  }

  /// While its port is empty an ejected device is still reported, with when to scan again; once
  /// the port has been empty for the settle time it is gone.
  @Test func ejectedDeviceIsReportedWhileSettlingThenForgotten() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)
    bus.plug([])

    #expect(
      try await registry.scan()
        == DeviceScan(devices: [], ejected: [Self.info(1)], rescanAfter: .seconds(3)))
    bus.advance(by: .seconds(1))
    #expect(
      try await registry.scan()
        == DeviceScan(devices: [], ejected: [Self.info(1)], rescanAfter: .seconds(2)))
    bus.advance(by: .seconds(2))
    #expect(try await registry.scan() == DeviceScan(devices: []))
  }

  @Test func ejectedDeviceUnpluggedForLongerThanTheSettleTimeIsOpenedAgain() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)
    bus.plug([])
    _ = try await registry.scan()

    bus.advance(by: .seconds(3))
    bus.plug([1])

    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
  }

  @Test func ejectedDeviceIsOpenedAgainOnceUnparked() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)
    bus.reenumerate(1, at: 12)

    await registry.unpark(Self.id(1))

    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
  }

  /// The ejected unit plugged into another port: it is opened once (only then is its serial
  /// known), let go, and from then on that port is ejected too, so its resets are not opened.
  @Test func ejectedDeviceOnAnotherPortIsOpenedOnceThenLeftAlone() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)
    await bus.log.setMoved(2, from: 1)
    await bus.log.setResetsOnClose(bus)
    bus.plug([2])

    for _ in 0..<3 {
      let scan = try await registry.scan()
      #expect(scan.devices.isEmpty)
      #expect(scan.ejected == [Self.info(1)])
      bus.reenumerate(2, at: 20)
    }
    #expect(await bus.log.opens == [1: 1, 2: 1])
    #expect(await bus.log.closes == [2: 1])
  }

  /// Only a device Ferry could use stands for the ejected one on its port: a keyboard plugged
  /// into that port leaves the port counting as empty.
  @Test func nonCandidateOnAnEjectedPortIsNotTheEjectedDevice() async throws {
    let bus = Bus([1])
    let registry = makeRegistry(bus)
    _ = try await registry.scan()
    let opened = try await registry.open(Self.id(1))
    await registry.park(Self.id(1))
    await registry.release(opened.location)

    bus.plug([1], apple: [1])

    #expect(
      try await registry.scan()
        == DeviceScan(devices: [], ejected: [Self.info(1)], rescanAfter: .seconds(3)))
  }
}
