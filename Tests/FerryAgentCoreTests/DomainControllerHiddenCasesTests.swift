import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The ways a device stops being served other than an unplug, each of which hides its location.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerHiddenCasesTests {
  /// A device still plugged in but locked shares no files: its location is hidden, and shown
  /// again once it is unlocked.
  @Test func aLockedDeviceIsHidden() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    await device.setLocked(true)
    _ = await harness.service.handle(.recheck(device.info.id), file: nil)
    #expect(await harness.manager.waitUntilHidden([domain]) == [domain])
    #expect(await harness.manager.registered.contains(domain))

    await device.setLocked(false)
    _ = await harness.service.handle(.recheck(device.info.id), file: nil)
    #expect(await harness.manager.waitUntilHidden([]).isEmpty)
    #expect(await harness.manager.shownButDisconnected.isEmpty)
  }

  /// An SD card has a location per method. When the device moves to ADB its MTP card location
  /// is hidden while the ADB one shows, and the other way round when it moves back.
  @Test func aMethodChangeHidesTheOldCardLocation() async throws {
    let cards = DomainControllerCardTests()
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [try await cards.mtp()], adb: adbTransport)
    defer { harness.finish() }
    let internalDomain = DomainNaming.identifier(for: neutralStorage("S1").id)
    let mtpCard = DomainControllerCardTests.oldCardDomain
    let adbCard = DomainControllerCardTests.cardDomain
    _ = await harness.manager.waitForCalls(2)

    await adbTransport.attach(try await cards.adb())
    harness.tick()
    let overADB = await harness.manager.waitUntil {
      $0.hidden == [mtpCard] && $0.registered.contains(adbCard)
    }
    #expect(overADB.hidden == [mtpCard])
    #expect(await harness.manager.visible == [internalDomain, adbCard])

    await adbTransport.detach(DomainControllerCardTests.id)
    harness.tick()
    #expect(await harness.manager.waitUntilHidden([adbCard]) == [adbCard])
    #expect(await harness.manager.visible == [internalDomain, mtpCard])
    #expect(await harness.manager.shownButDisconnected.isEmpty)
  }

  /// A hidden location is never renamed: a second device of its model arriving while it is away
  /// renames it only once it is back, after its reconnect, so a rename never shows it early.
  @Test func aHiddenLocationIsRenamedOnlyOnceBack() async throws {
    let first = await makeDevice("SER0000AAAA")
    let harness = try AgentHarness(devices: [first])
    defer { harness.finish() }
    let domain = domainID(first)
    _ = await harness.manager.waitForCalls(1)
    await harness.transport.detach(first.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)

    let second = await makeDevice("SER0000BBBB")
    await harness.transport.attach(second)
    harness.tick()
    _ = await harness.manager.waitForCalls(3)
    #expect(await harness.manager.hidden == [domain])
    #expect(
      !(await harness.manager.calls.contains(
        .add(DomainSpec(identifier: domain, displayName: "Phone (AAAA)")))))

    await harness.transport.attach(await makeDevice("SER0000AAAA"))
    harness.tick()
    let renamed = FakeDomainManager.Call.add(
      DomainSpec(identifier: domain, displayName: "Phone (AAAA)"))
    let calls = await harness.manager.waitForCalls(6)
    let reconnect = try #require(calls.firstIndex(of: .reconnect(domain)))
    let rename = try #require(calls.firstIndex(of: renamed))
    #expect(reconnect < rename)
    #expect(await harness.manager.waitUntilHidden([]).isEmpty)
  }
}
