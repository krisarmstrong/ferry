import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// Actor review: state the hub keeps for a device goes with it.
extension DeviceHubMethodTests {
  /// A move to ADB that was not ready holds off the next try. The device then leaves and comes
  /// back: the hold was the old connection's, so ADB turning up for the new one moves it at
  /// once, without waiting out the old back-off.
  @Test func aDeviceThatLeftLosesItsSwapHold() async throws {
    var harness = await MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await adbDevice.setLocked(true)
    await harness.adb.attach(adbDevice)
    harness.tick()
    while await harness.adb.openCount(of: id) == 0, !Task.isCancelled { await Task.yield() }
    while await harness.hub.isSwapping(id), !Task.isCancelled { await Task.yield() }

    await harness.mtp.detach(id)
    await harness.adb.detach(id)
    harness.tick()
    #expect(await harness.next() == .detached(id))
    // A detached fake stays unplugged: the replug is a new one.
    let (mtpAgain, adbAgain) = (viaMTP("S1"), viaADB("S1"))
    await harness.mtp.attach(mtpAgain)
    harness.tick()
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))

    await harness.adb.attach(adbAgain)
    await harness.hub.reconcile()
    let moving = await harness.hub.isSwapping(id)
    let opened = await harness.adb.openCount(of: id)
    try #require(moving || opened == 2)
    #expect(await harness.next() == .changed(ready(mtpDevice, .usbADB)))
  }

  /// A device with a swap hold is let go to another app (busy), then unplugged: its hold goes
  /// with the unheld entry.
  @Test func anUnheldDeviceThatLeftLosesItsSwapHold() async throws {
    var harness = await MethodHarness(mtp: [mtpDevice])
    defer { harness.finish() }
    #expect(await harness.next() == .attached(ready(mtpDevice, .usbFileTransfer)))
    await adbDevice.setLocked(true)
    await harness.adb.attach(adbDevice)
    harness.tick()
    while await harness.adb.openCount(of: id) == 0, !Task.isCancelled { await Task.yield() }
    while await harness.hub.isSwapping(id), !Task.isCancelled { await Task.yield() }
    try #require(await harness.hub.swapHolds[id] != nil)

    await harness.adb.detach(id)
    await harness.mtp.setBusyKeepsSerial(true)
    await harness.mtp.setHeldByAnotherApp(id, true)
    harness.tick()
    let released = await harness.next()
    guard case .changed(let busy) = released else {
      Issue.record("expected the device listed busy, got \(String(describing: released))")
      return
    }
    #expect(busy.state == .busy)
    await harness.mtp.detach(id)
    harness.tick()
    #expect(await harness.next() == .detached(id))

    #expect(await harness.hub.swapHolds[id] == nil)
  }

  /// A move whose new session cannot be opened, with no MTP session to fall back on, drops the
  /// device. No hold is left behind for it: the device it would hold off is gone.
  @Test func aMoveThatDropsTheDeviceLeavesNoSwapHold() async throws {
    var harness = await MethodHarness()
    defer { harness.finish() }
    await harness.adb.setMethod(.wifiADB, for: id)
    await harness.adb.attach(adbDevice)
    harness.tick()
    #expect(await harness.next() == .attached(ready(adbDevice, .wifiADB)))

    await harness.adb.setMethod(.usbADB, for: id)
    await harness.adb.failNextOpen(of: id, with: .io("open failed"))
    harness.tick()
    #expect(await harness.next() == .detached(id))
    while await harness.hub.isSwapping(id), !Task.isCancelled { await Task.yield() }

    #expect(await harness.hub.swapHolds[id] == nil)
  }
}
