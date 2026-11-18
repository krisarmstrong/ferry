import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// Devices the hub leaves to the transport: ejected, busy, or without file transfer.
extension DeviceHubTests {
  @Test func ejectParksTheDeviceInTheTransport() async {
    let device = await makeHubDevice("A")
    var harness = HubHarness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(hubReady(device)))
    await harness.hub.eject(device.info.id)
    #expect(await harness.transport.isParked(device.info.id))
  }

  /// File transfer off: the transport sees the device on USB only, and nothing is opened.
  @Test func deviceWithoutFileTransferIsNotSharing() async {
    let info = DeviceInfo(
      id: DeviceID(serial: "usb-0-3"), manufacturer: "freescale", model: "LinkRunner-100G")
    var harness = HubHarness()
    defer { harness.finish() }
    await harness.transport.attachWithoutFileTransfer(info)
    harness.tick()

    #expect(await harness.next() == .attached(AttachedDevice(info: info, state: .notSharingFiles)))
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
    var harness = HubHarness()
    defer { harness.finish() }
    await harness.transport.failNextOpen(of: device.info.id, with: .deviceBusy)
    await harness.transport.attach(device)
    harness.tick()
    #expect(await harness.next() == .attached(AttachedDevice(info: device.info, state: .busy)))
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
    var harness = HubHarness(devices: [first, second])
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

  /// Closing an ejected Android unit resets it; the transport sees a new enumeration it does not
  /// know was ejected. The hub still does not open it, until Try Again.
  @Test func ejectSticksAcrossTheDevicesOwnResetUntilTryAgain() async {
    let device = await makeHubDevice("A")
    var harness = HubHarness(devices: [device])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(hubReady(device)))
    await harness.transport.resetOnClose(device.info.id)
    await harness.hub.eject(device.info.id)
    #expect(
      await harness.next() == .changed(AttachedDevice(info: device.info, state: .notSharingFiles)))
    harness.tick()
    #expect(await harness.barrier()?.isAttached(serial: "BARRIER") == true)
    #expect(await harness.transport.openCount(of: device.info.id) == 1)

    await harness.hub.recheck(device.info.id)
    #expect(await harness.next() == .changed(hubReady(device)))
  }

  @Test func ejectedDeviceUnpluggedAndReplugggedIsOpenedAgain() async {
    let device = await makeHubDevice("A")
    var harness = HubHarness(devices: [device])
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
}
