import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// A hub over MTP and ADB fakes behind a `CompositeTransport`, with ticks under the test's control.
struct MethodHarness {
  let mtp: FakeTransport
  let adb: FakeTransport
  let clock = ManualClock()
  let hub: DeviceHub
  private let ticks: AsyncStream<Void>.Continuation
  var events: AsyncStream<HubEvent>.Iterator

  init(mtp: [FakeDevice] = [], adb: [FakeDevice] = []) {
    self.mtp = FakeTransport(devices: mtp)
    self.adb = FakeTransport(devices: adb, method: .usbADB)
    let (arrivals, ticks) = AsyncStream.makeStream(of: Void.self)
    self.ticks = ticks
    hub = DeviceHub(
      transport: CompositeTransport(mtp: self.mtp, adb: self.adb), arrivals: arrivals,
      clock: clock)
    events = hub.events.makeAsyncIterator()
  }

  func tick() {
    ticks.yield()
  }

  mutating func next() async -> HubEvent? {
    await events.next()
  }

  func finish() {
    ticks.finish()
  }
}

func ready(_ device: FakeDevice, as info: DeviceInfo? = nil, _ method: ConnectionMethod)
  -> AttachedDevice
{
  AttachedDevice(
    info: info ?? device.info, state: .ready([neutralStorage(device.info.id.serial)]),
    method: method)
}

@Suite(.timeLimit(.minutes(1)))
struct DeviceHubMethodTests {
  let mtpDevice = viaMTP("S1")
  let adbDevice = viaADB("S1")
  var id: DeviceID { mtpDevice.info.id }

  /// ADB turns up for a device MTP serves: the hub moves it to ADB and reports the method. The
  /// MTP session is kept, idle: releasing it would reset the unit, and the reset would drop the
  /// ADB route that replaces it.
  @Test func adbReplacesAHeldMTPSessionWithoutReleasingIt() async throws {
    var harness = MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))

    await harness.adb.attach(adbDevice)
    harness.tick()

    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))
    #expect(try await harness.hub.session(for: id).info == adbDevice.info)
    #expect(await harness.mtp.openCount(of: id) == 1)
    #expect(await mtpDevice.closeCount == 0)
    #expect(await harness.adb.openCount(of: id) == 1)
  }

  /// USB debugging revoked: adb lists the device as unauthorized and MTP serves it again, from
  /// the session it kept.
  @Test func revokingADBFallsBackToTheKeptMTPSession() async throws {
    var harness = MethodHarness(mtp: [mtpDevice], adb: [])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))

    await harness.adb.detach(id)
    await harness.adb.attachWithoutFileTransfer(adbDevice.info)
    harness.tick()

    #expect(await harness.next() == .changed(ready(mtpDevice, .usbFileTransfer)))
    #expect(try await harness.hub.session(for: id).info == mtpDevice.info)
    #expect(await harness.mtp.openCount(of: id) == 1)
    #expect(await adbDevice.closeCount == 1)
  }

  /// Review Focus 2: seen over both from the start, the device is one entry with one session.
  @Test func aDeviceSeenTwiceIsOpenedOnce() async throws {
    var harness = MethodHarness(mtp: [mtpDevice], adb: [adbDevice])
    defer { harness.finish() }

    #expect(await harness.next() == .attached(ready(mtpDevice, .usbADB)))
    #expect(await harness.hub.devices() == [ready(mtpDevice, .usbADB)])
    #expect(await harness.mtp.openCount(of: id) == 0)
    #expect(await harness.adb.openCount(of: id) == 1)
  }

  /// The cable goes in while the device is served over the network: ADB's own session moves to
  /// USB. adb holds one session per device, so the old one is closed first.
  @Test func pluggingInMovesAnADBSessionFromTheNetworkToUSB() async throws {
    var harness = MethodHarness()
    defer { harness.finish() }
    await harness.adb.setMethod(.wifiADB, for: id)
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .attached(ready(adbDevice, .wifiADB)))

    await harness.adb.setMethod(.usbADB, for: id)
    harness.tick()

    #expect(await harness.next() == .changed(ready(adbDevice, .usbADB)))
    #expect(await harness.adb.openCount(of: id) == 2)
    #expect(await adbDevice.closeCount == 1)
  }

  /// Review Focus 1: the hub swaps only between requests. A request in flight finishes on the
  /// old session; one that arrives meanwhile waits and runs on the new one.
  @Test func aSwapWaitsForRequestsInFlight() async throws {
    var harness = MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    let lease = try await harness.hub.lease(id)
    #expect(lease.session.info == mtpDevice.info)

    await harness.adb.attach(adbDevice)
    harness.tick()
    while await !harness.hub.isSwapping(id) { await Task.yield() }
    let waiting = Task { [hub = harness.hub, id] in
      let later = try await hub.lease(id)
      await hub.release(later)
      return later.session.info
    }
    while await harness.hub.requestsAwaitingSwap == 0 { await Task.yield() }
    #expect(await harness.hub.devices() == [ready(mtpDevice, .usbFileTransfer)])

    await harness.hub.release(lease)

    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))
    #expect(try await waiting.value == adbDevice.info)
  }

  /// A device ejected while its swap waits is not reopened by the swap.
  @Test func anEjectDuringASwapWins() async throws {
    var harness = MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    let lease = try await harness.hub.lease(id)
    await harness.adb.attach(adbDevice)
    harness.tick()
    while await !harness.hub.isSwapping(id) { await Task.yield() }

    await harness.hub.release(lease)
    await harness.hub.eject(id)

    let devices = await harness.hub.devices()
    #expect(devices.map(\.state) == [.ejected])
    #expect(await harness.adb.isParked(id))
    #expect(await harness.mtp.isParked(id))
    #expect(await !adbDevice.isOpen)
    #expect(await !mtpDevice.isOpen)
  }

  /// Ejecting closes the kept MTP session too, so the device is left alone over both.
  @Test func ejectClosesTheKeptSession() async throws {
    var harness = MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))

    await harness.hub.eject(id)

    #expect(
      await harness.next()
        == .changed(
          AttachedDevice(info: mtpDevice.info, state: .ejected, method: .usbADB)))
    #expect(await mtpDevice.closeCount == 1)
    #expect(await adbDevice.closeCount == 1)
    #expect(await harness.mtp.isParked(id))
    #expect(await harness.adb.isParked(id))
  }

  /// The network drops while USB has gone: the ADB session reports the device gone, and the kept
  /// MTP session is gone too, so the device is detached rather than served by a dead session.
  @Test func aGoneDeviceClosesItsKeptSession() async throws {
    var harness = MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))

    await harness.mtp.detach(id)
    await harness.adb.detach(id)
    harness.tick()

    #expect(await harness.next() == .detached(id))
    #expect(await mtpDevice.closeCount == 1)
  }
}
