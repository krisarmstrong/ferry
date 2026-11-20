import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// Review fixes: USB presence, failed scans, ejects, back-off and stale releases.
extension DeviceHubMethodTests {
  // MARK: Fix round 2

  /// A held USB session is never moved to the network in place: the cable pull is learnt from
  /// the session, the device is detached, and the network then serves it afresh.
  @Test func pullingTheCableHandsOverToTheNetworkThroughADetach() async throws {
    var harness = await MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await harness.adb.setMethod(.wifiADB, for: id)
    await harness.adb.attach(adbDevice)

    await harness.mtp.detach(id)
    harness.tick()

    #expect(await harness.next() == .detached(id))
    #expect(await harness.next() == .attached(ready(mtpDevice, .wifiADB)))
    #expect(await mtpDevice.closeCount == 1)
  }

  /// MTP's scan fails while the unit is also on the network: it stays on MTP.
  @Test func aFailedScanNeverMovesAUSBDeviceToTheNetwork() async throws {
    var harness = await MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await harness.adb.setMethod(.wifiADB, for: id)
    await harness.adb.attach(adbDevice)
    await harness.mtp.failScans(with: .io("registry"))

    harness.tick()
    let scans = await harness.mtp.scanCount
    while await harness.mtp.scanCount == scans, !Task.isCancelled { await Task.yield() }
    while await harness.hub.isSwapping(id), !Task.isCancelled { await Task.yield() }

    #expect(await harness.hub.devices() == [ready(mtpDevice, .usbFileTransfer)])
    #expect(await harness.adb.openCount(of: id) == 0)
  }

  /// The unit is served over the network and is then plugged in with file transfer off: USB
  /// presents it, so the network stops serving it and it shows as not sharing.
  @Test func aUSBDeviceNotSharingTakesTheDeviceFromTheNetwork() async throws {
    var harness = await MethodHarness()
    defer { harness.finish() }
    await harness.adb.setMethod(.wifiADB, for: id)
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .attached(ready(adbDevice, .wifiADB)))

    await harness.mtp.attachWithoutFileTransfer(mtpDevice.info)
    harness.tick()

    #expect(
      await harness.next()
        == .changed(
          AttachedDevice(info: mtpDevice.info, state: .notSharingFiles, method: .usbFileTransfer)))
    #expect(await adbDevice.closeCount == 1)
  }

  /// Once an eject has begun, no new request gets the device's session.
  @Test func noLeaseOnceAnEjectHasBegun() async throws {
    var harness = await MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    let lease = try await harness.hub.lease(id)
    let eject = Task { [hub = harness.hub, id] in await hub.eject(id) }
    while await harness.hub.waitingForRequests == 0, !Task.isCancelled { await Task.yield() }

    await #expect(throws: TransportError.deviceNotFound(id)) {
      _ = try await harness.hub.lease(id)
    }
    await harness.hub.release(lease)
    await eject.value
  }

  /// ADB that stays not ready is tried again after a back-off, not on every scan.
  @Test func aNotReadyADBIsRetriedAfterABackOff() async throws {
    var harness = await MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await adbDevice.setLocked(true)
    await harness.adb.attach(adbDevice)
    harness.tick()
    while await harness.adb.openCount(of: id) == 0, !Task.isCancelled { await Task.yield() }
    while await harness.hub.isSwapping(id), !Task.isCancelled { await Task.yield() }

    for _ in 0..<3 {
      let scans = await harness.adb.scanCount
      harness.tick()
      while await harness.adb.scanCount == scans, !Task.isCancelled { await Task.yield() }
    }
    while await harness.hub.isSwapping(id), !Task.isCancelled { await Task.yield() }
    #expect(await harness.adb.openCount(of: id) == 1)

    await adbDevice.setLocked(false)
    await harness.clock.advance(by: DeviceHub.firstRetryDelay)
    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))
  }

  // MARK: Fix round 3

  /// The cable is plugged in (file transfer off) while a copy runs over the network, and pulled
  /// again before the copy ends. Once the copy ends, the device is served over the network
  /// again, not left as not sharing.
  @Test func aReleaseReconcilesOnceTheRequestsFinish() async throws {
    var harness = await MethodHarness()
    defer { harness.finish() }
    await harness.adb.setMethod(.wifiADB, for: id)
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .attached(ready(adbDevice, .wifiADB)))
    let lease = try await harness.hub.lease(id)

    await harness.mtp.attachWithoutFileTransfer(mtpDevice.info)
    harness.tick()
    while await harness.hub.waitingForRequests == 0, !Task.isCancelled { await Task.yield() }
    await harness.mtp.detach(id)
    // A whole reconcile runs while the release still waits: it sees the cable gone.
    let barrier = await makeHubDevice("BARRIER")
    await harness.mtp.attach(barrier)
    harness.tick()
    #expect(await harness.next() == .attached(hubReady(barrier)))
    await harness.hub.release(lease)

    // Named as MTP named it when it was seen on the cable.
    let served = ready(adbDevice, as: mtpDevice.info, .wifiADB)
    while await harness.hub.devices().first(where: { $0.id == id }) != served, !Task.isCancelled {
      await Task.yield()
    }
    #expect(await harness.hub.devices().first { $0.id == id } == served)
    #expect(await harness.adb.openCount(of: id) == 2)
  }
}
