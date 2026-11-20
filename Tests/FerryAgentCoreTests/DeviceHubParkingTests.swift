import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// Devices the hub leaves to the transport: ejected, busy, or without file transfer.
extension DeviceHubTests {
  @Test func ejectParksTheDeviceInTheTransport() async {
    let device = await makeHubDevice("A")
    var harness = await HubHarness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(hubReady(device)))
    await harness.hub.eject(device.info.id)
    #expect(await harness.transport.isParked(device.info.id))
  }

  /// File transfer off: the transport sees the device on USB only, and nothing is opened.
  @Test func deviceWithoutFileTransferIsNotSharing() async {
    let info = DeviceInfo(
      id: DeviceID(serial: "usb-0-3"), manufacturer: "freescale", model: "LinkRunner-100G")
    var harness = await HubHarness()
    defer { harness.finish() }
    await harness.transport.attachWithoutFileTransfer(info)
    harness.tick()

    #expect(
      await harness.next()
        == .attached(AttachedDevice(info: info, state: .notSharingFiles, method: .usbFileTransfer)))
    #expect(await harness.clock.sleepCount == 0)

    await harness.transport.detach(info.id)
    let device = await makeHubDevice("A")
    await harness.transport.attach(device)
    harness.tick()
    #expect(await harness.next() == .detached(info.id))
    #expect(await harness.next() == .attached(hubReady(device)))
  }

  @Test func recheckOfBusyDeviceUnparksAndScans() async {
    let device = await makeHubDevice("A")
    var harness = await HubHarness()
    defer { harness.finish() }
    await harness.transport.failNextOpen(of: device.info.id, with: .deviceBusy)
    await harness.transport.attach(device)
    harness.tick()
    #expect(
      await harness.next()
        == .attached(AttachedDevice(info: device.info, state: .busy, method: .usbFileTransfer)))
    await harness.transport.park(device.info.id)

    await harness.hub.recheck(device.info.id)

    #expect(await !harness.transport.isParked(device.info.id))
    #expect(await harness.next() == .changed(hubReady(device)))
  }

  /// The hub's own re-check of waiting devices must not offer an ejected one to the transport
  /// again, even when the eject lands while the poll is under way.
  @Test func pollDoesNotUnparkADeviceEjectedMeanwhile() async {
    let first = await makeHubDevice("A", locked: true)
    let second = await makeHubDevice("B", locked: true)
    var harness = await HubHarness(devices: [first, second])
    defer { harness.finish() }
    _ = await harness.next()
    _ = await harness.next()
    await harness.clock.waitForSleeper()

    await first.suspendNext(.storages)
    await harness.clock.advance(by: .seconds(2))
    await first.waitUntilSuspended(.storages)
    await harness.hub.eject(second.info.id)
    #expect(
      await harness.next()
        == .changed(AttachedDevice(info: second.info, state: .ejected, method: .usbFileTransfer)))
    await first.resume(.storages)
    await harness.clock.waitForSleeper()
    harness.tick()
    let barrier = await harness.barrier()

    #expect(barrier?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.transport.isParked(second.info.id))
    #expect(await harness.transport.openCount(of: second.info.id) == 1)
  }

  /// Closing an ejected Android unit resets it: gone for a moment, then back. The transport
  /// keeps reporting it as ejected, and it is not opened until Mount.
  @Test func ejectSticksAcrossTheDevicesOwnResetUntilMount() async {
    let device = await makeHubDevice("A")
    var harness = await HubHarness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(hubReady(device)))
    await harness.hub.eject(device.info.id)
    #expect(
      await harness.next()
        == .changed(AttachedDevice(info: device.info, state: .ejected, method: .usbFileTransfer)))
    for _ in 0..<2 {
      harness.tick()
    }
    let second = await makeHubDevice("SECOND")
    await harness.transport.attach(second)
    harness.tick()
    #expect(await harness.next() == .attached(hubReady(second)))
    #expect(await harness.hub.devices().first { $0.id == device.info.id }?.state == .ejected)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)

    await harness.hub.recheck(device.info.id)
    #expect(await harness.next() == .changed(hubReady(device)))
  }

  /// The hub follows the transport: once the transport offers an ejected device as usable (it
  /// counted as unplugged, or turned up where the transport opened it), the hub mounts it rather
  /// than showing "Ejected" for a device it could hold.
  @Test func ejectedDeviceTheTransportOffersAgainIsMounted() async {
    let device = await makeHubDevice("A")
    var harness = await HubHarness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(hubReady(device)))
    await harness.hub.eject(device.info.id)
    #expect(
      await harness.next()
        == .changed(AttachedDevice(info: device.info, state: .ejected, method: .usbFileTransfer)))

    await harness.transport.forgetEjection(device.info.id)
    harness.tick()

    #expect(await harness.next() == .changed(hubReady(device)))
  }

  @Test func ejectedDeviceUnpluggedAndReplugggedIsOpenedAgain() async {
    let device = await makeHubDevice("A")
    var harness = await HubHarness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(hubReady(device)))
    await harness.hub.eject(device.info.id)
    _ = await harness.next()

    await harness.transport.detach(device.info.id)
    harness.tick()
    #expect(await harness.next() == .detached(device.info.id))
    let replugged = await makeHubDevice("A")
    await harness.transport.attach(replugged)
    harness.tick()
    #expect(await harness.next() == .attached(hubReady(replugged)))
  }

  /// A device whose storages keep failing is closed each time, which can reset it into a new
  /// enumeration and a new tick. Retries back off, 2 s doubling to 60 s, and Try Again retries
  /// at once.
  @Test func failingDeviceIsRetriedWithBackoff() async {
    let device = await makeHubDevice("A")
    await device.failStorages(with: .io("broken"))
    var harness = await HubHarness(devices: [device])
    defer { harness.finish() }
    let failed = AttachedDevice(
      info: device.info, state: .failed(.io("broken")), method: .usbFileTransfer)
    #expect(await harness.next() == .attached(failed))
    await harness.clock.waitForSleeper()

    harness.tick()
    #expect(await harness.barrier()?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)

    await harness.clock.advance(by: .seconds(2))
    await harness.clock.waitForSleeper()
    #expect(await harness.transport.openCount(of: device.info.id) == 2)

    await harness.clock.advance(by: .seconds(2))
    harness.tick()
    let other = await makeHubDevice("OTHER")
    await harness.transport.attach(other)
    harness.tick()
    #expect(await harness.next() == .attached(hubReady(other)))
    #expect(await harness.transport.openCount(of: device.info.id) == 2)

    await device.failStorages(with: nil)
    await harness.hub.recheck(device.info.id)
    #expect(await harness.next() == .changed(hubReady(device)))
    #expect(await harness.transport.openCount(of: device.info.id) == 3)
  }

  /// An ejected device's port is empty: the transport asks for another scan once that would count
  /// as an unplug, and the hub scans then without waiting for a USB event.
  @Test func hubScansAgainWhenTheTransportAsks() async {
    var harness = await HubHarness()
    defer { harness.finish() }
    await harness.transport.setRescanAfter(.seconds(3))
    harness.tick()
    await harness.clock.waitForSleeper()
    await harness.transport.setRescanAfter(nil)
    // Plugged in with no USB tick: only the rescan can find it.
    let device = await makeHubDevice("A")
    await harness.transport.attach(device)

    await harness.clock.advance(by: .seconds(3))

    #expect(await harness.next() == .attached(hubReady(device)))
  }
}
