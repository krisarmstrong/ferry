import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

private func makeDevice(_ serial: String, locked: Bool = false) async -> FakeDevice {
  let id = DeviceID(serial: serial)
  let device = FakeDevice(
    info: DeviceInfo(id: id, manufacturer: "Fake", model: "Phone"),
    storages: [storage(of: id)])
  await device.setLocked(locked)
  return device
}

private func storage(of id: DeviceID) -> StorageInfo {
  StorageInfo(
    id: StorageID(device: id, key: "Internal|vol0"), description: "Internal", capacity: 1_000,
    free: 900)
}

private func ready(_ device: FakeDevice) -> AttachedDevice {
  AttachedDevice(info: device.info, state: .ready([storage(of: device.info.id)]))
}

/// A hub over a fake transport, with USB ticks and time under the test's control.
private struct Harness {
  let transport: FakeTransport
  let clock = ManualClock()
  let hub: DeviceHub
  private let ticks: AsyncStream<Void>.Continuation
  var events: AsyncStream<HubEvent>.Iterator

  init(devices: [FakeDevice] = []) {
    transport = FakeTransport(devices: devices)
    let (arrivals, ticks) = AsyncStream.makeStream(of: Void.self)
    self.ticks = ticks
    hub = DeviceHub(transport: transport, arrivals: arrivals, clock: clock)
    events = hub.events.makeAsyncIterator()
  }

  func tick() {
    ticks.yield()
  }

  mutating func next() async -> HubEvent? {
    await events.next()
  }

  /// Plugs in a fresh device and returns once the hub reports it. Every event the hub emitted
  /// before that arrives first, so a test can check nothing else happened in between.
  mutating func barrier() async -> HubEvent? {
    let other = await makeDevice("BARRIER")
    await transport.attach(other)
    tick()
    return await next()
  }

  func finish() {
    ticks.finish()
  }
}

/// Every wait here is on an event the hub should emit, so a regression hangs; the limit fails it.
@Suite(.timeLimit(.minutes(1)))
struct DeviceHubTests {
  @Test func attachEmitsReadyWithStorages() async throws {
    var harness = Harness()
    defer { harness.finish() }
    let device = await makeDevice("A")
    await harness.transport.attach(device)
    harness.tick()

    #expect(await harness.next() == .attached(ready(device)))
    #expect(await harness.hub.devices() == [ready(device)])
    #expect(try await harness.hub.session(for: device.info.id).info == device.info)
  }

  @Test func lockedDeviceIsNotSharingFilesThenBecomesReady() async {
    let device = await makeDevice("A", locked: true)
    var harness = Harness(devices: [device])
    defer { harness.finish() }

    #expect(
      await harness.next() == .attached(AttachedDevice(info: device.info, state: .notSharingFiles)))
    await harness.clock.waitForSleeper()
    await device.setLocked(false)
    await harness.clock.advance(by: .seconds(2))

    #expect(await harness.next() == .changed(ready(device)))
    #expect(await !harness.hub.isRechecking)
    #expect(await harness.clock.sleepCount == 1)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)
  }

  @Test func heldDeviceIsNeverBusy() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    harness.tick()
    harness.tick()
    let barrier = await harness.barrier()

    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)
    #expect(await harness.hub.devices().first { $0.id == device.info.id } == ready(device))
  }

  @Test func openBusyDeviceIsBusyUntilItFrees() async {
    let device = await makeDevice("A")
    var harness = Harness()
    defer { harness.finish() }
    await harness.transport.failNextOpen(of: device.info.id, with: .deviceBusy)
    await harness.transport.attach(device)
    harness.tick()

    #expect(await harness.next() == .attached(AttachedDevice(info: device.info, state: .busy)))
    harness.tick()
    #expect(await harness.next() == .changed(ready(device)))
  }

  @Test func anotherAppHoldingDeviceIsReportedBusy() async {
    let device = await makeDevice("A")
    let busy = AttachedDevice(
      info: DeviceInfo(
        id: FakeTransport.busyID(for: device.info.id), manufacturer: "Fake", model: "Phone"),
      state: .busy)
    var harness = Harness()
    defer { harness.finish() }
    await harness.transport.attach(device)
    await harness.transport.setHeldByAnotherApp(device.info.id, true)
    harness.tick()

    #expect(await harness.next() == .attached(busy))
    #expect(await harness.transport.openCount(of: device.info.id) == 0)
    harness.tick()
    let barrier = await harness.barrier()
    #expect(barrier?.isAttached(serial: "BARRIER") == true)

    await harness.transport.setHeldByAnotherApp(device.info.id, false)
    harness.tick()
    #expect(await harness.next() == .detached(busy.id))
    #expect(await harness.next() == .attached(ready(device)))
  }

  @Test func scanNeverOpensHeldDevice() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))
    let probes = await harness.transport.probeCount(of: device.info.id)

    for _ in 0..<5 { harness.tick() }
    _ = await harness.barrier()

    #expect(await harness.transport.probeCount(of: device.info.id) == probes)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)
  }

  @Test func noRepeatedOpensPerTick() async {
    let devices = [await makeDevice("A"), await makeDevice("B"), await makeDevice("C")]
    var harness = Harness()
    defer { harness.finish() }
    for device in devices { await harness.transport.attach(device) }
    let scansBefore = await harness.transport.scanCount
    harness.tick()
    for _ in devices { _ = await harness.next() }

    #expect(await harness.transport.scanCount == scansBefore + 1)
    for device in devices {
      #expect(await harness.transport.openCount(of: device.info.id) == 1)
      #expect(await harness.transport.probeCount(of: device.info.id) == 1)
    }
  }

  @Test func failedStoragesReleasesSessionForRetry() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    await device.failNextStorages(with: .io("stall"))
    await harness.hub.recheck(device.info.id)

    let failed = AttachedDevice(info: device.info, state: .failed(.io("stall")))
    #expect(await harness.next() == .changed(failed))
    #expect(await device.closeCount == 1)
    await #expect(throws: TransportError.io("stall")) {
      _ = try await harness.hub.session(for: device.info.id)
    }
    harness.tick()
    #expect(await harness.next() == .changed(ready(device)))
    #expect(await harness.transport.openCount(of: device.info.id) == 2)
  }

  @Test func detachClosesSessionAndEmits() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    await harness.transport.detach(device.info.id)
    harness.tick()

    #expect(await harness.next() == .detached(device.info.id))
    #expect(await device.closeCount == 1)
    #expect(await harness.hub.devices().isEmpty)
    await #expect(throws: TransportError.deviceNotFound(device.info.id)) {
      _ = try await harness.hub.session(for: device.info.id)
    }
  }

  @Test func replugBeforeTickIsReattached() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    await harness.transport.detach(device.info.id)
    let replugged = await makeDevice("A")
    await harness.transport.attach(replugged)
    harness.tick()

    #expect(await harness.next() == .detached(device.info.id))
    #expect(await harness.next() == .attached(ready(replugged)))
    #expect(await replugged.isOpen)
  }

  /// The old session's close can take a while on USB; a replug ticked meanwhile must not be
  /// reported before the departure it follows.
  @Test func replugDuringCloseIsReportedAfterDetach() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    await device.suspendNext(.close)
    await harness.transport.detach(device.info.id)
    let replugged = await makeDevice("A")
    await harness.transport.attach(replugged)
    harness.tick()
    await device.waitUntilSuspended(.close)
    harness.tick()
    let barrier = await harness.barrier()
    await device.resume(.close)

    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.next() == .detached(device.info.id))
    #expect(await harness.next() == .attached(ready(replugged)))
  }

  @Test func ejectKeepsDeviceListed() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    await harness.hub.eject(device.info.id)

    let ejected = AttachedDevice(info: device.info, state: .notSharingFiles)
    #expect(await harness.next() == .changed(ejected))
    #expect(await device.closeCount == 1)
    harness.tick()
    let barrier = await harness.barrier()
    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.hub.devices().first { $0.id == device.info.id } == ejected)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)
    #expect(await harness.clock.sleepCount == 0)
    await #expect(throws: TransportError.deviceNotFound(device.info.id)) {
      _ = try await harness.hub.session(for: device.info.id)
    }
  }

  @Test func ejectDuringRecheckStaysEjected() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))

    await device.suspendNext(.storages)
    let hub = harness.hub
    async let recheck: Void = hub.recheck(device.info.id)
    await device.waitUntilSuspended(.storages)
    await hub.eject(device.info.id)
    await device.resume(.storages)
    await recheck

    let ejected = AttachedDevice(info: device.info, state: .notSharingFiles)
    #expect(await harness.next() == .changed(ejected))
    let barrier = await harness.barrier()
    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.hub.devices().first { $0.id == device.info.id } == ejected)
  }

  @Test func noPollingWhenNothingWaits() async {
    let device = await makeDevice("A")
    let locked = await makeDevice("L", locked: true)
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))
    #expect(await !harness.hub.isRechecking)
    #expect(await harness.clock.sleepCount == 0)

    await harness.transport.attach(locked)
    harness.tick()
    #expect(
      await harness.next() == .attached(AttachedDevice(info: locked.info, state: .notSharingFiles)))
    #expect(await harness.hub.isRechecking)
    await harness.clock.waitForSleeper()

    await harness.hub.eject(locked.info.id)
    #expect(await !harness.hub.isRechecking)
    await harness.clock.advance(by: .seconds(10))
    let barrier = await harness.barrier()
    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.clock.sleepCount == 1)
  }
}

extension HubEvent {
  fileprivate func isAttached(serial: String) -> Bool {
    if case .attached(let device) = self { return device.id.serial == serial }
    return false
  }
}

extension DeviceHubTests {
  @Test func ejectParksTheDeviceInTheTransport() async {
    let device = await makeDevice("A")
    var harness = Harness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(device)))
    await harness.hub.eject(device.info.id)
    #expect(await harness.transport.isParked(device.info.id))
  }

  /// File transfer off: the transport sees the device on USB only, and nothing is opened.
  @Test func deviceWithoutFileTransferIsNotSharing() async {
    let info = DeviceInfo(
      id: DeviceID(serial: "usb-0-3"), manufacturer: "freescale", model: "LinkRunner-100G")
    var harness = Harness()
    defer { harness.finish() }
    await harness.transport.attachWithoutFileTransfer(info)
    harness.tick()

    #expect(await harness.next() == .attached(AttachedDevice(info: info, state: .notSharingFiles)))
    #expect(await harness.clock.sleepCount == 0)

    await harness.transport.detach(info.id)
    let device = await makeDevice("A")
    await harness.transport.attach(device)
    harness.tick()
    #expect(await harness.next() == .detached(info.id))
    #expect(await harness.next() == .attached(ready(device)))
  }

  @Test func recheckOfBusyDeviceUnparksAndScans() async {
    let device = await makeDevice("A")
    var harness = Harness()
    defer { harness.finish() }
    await harness.transport.failNextOpen(of: device.info.id, with: .deviceBusy)
    await harness.transport.attach(device)
    harness.tick()
    #expect(await harness.next() == .attached(AttachedDevice(info: device.info, state: .busy)))
    await harness.transport.park(device.info.id)

    await harness.hub.recheck(device.info.id)

    #expect(await !harness.transport.isParked(device.info.id))
    #expect(await harness.next() == .changed(ready(device)))
  }

  /// The hub's own re-check of waiting devices must not offer an ejected one to the transport
  /// again, even when the eject lands while the poll is under way.
  @Test func pollDoesNotUnparkADeviceEjectedMeanwhile() async {
    let first = await makeDevice("A", locked: true)
    let second = await makeDevice("B", locked: true)
    var harness = Harness(devices: [first, second])
    defer { harness.finish() }
    _ = await harness.next()
    _ = await harness.next()
    await harness.clock.waitForSleeper()

    await first.suspendNext(.storages)
    await harness.clock.advance(by: .seconds(2))
    await first.waitUntilSuspended(.storages)
    await harness.hub.eject(second.info.id)
    await first.resume(.storages)
    await harness.clock.waitForSleeper()
    harness.tick()
    let barrier = await harness.barrier()

    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.transport.isParked(second.info.id))
    #expect(await harness.transport.openCount(of: second.info.id) == 1)
  }
}
