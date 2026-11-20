import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A hidden location that still holds changes not sent to its device is named in the status, so
/// the menu can say they wait: nothing in Finder shows them while the location is hidden.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerWaitingTests {
  func waiting(_ harness: AgentHarness) async -> [String] {
    guard case .status(let report) = await harness.service.handle(.status, file: nil) else {
      Issue.record("expected a status")
      return []
    }
    return report.waitingToSend
  }

  @Test func anUnpluggedLocationWithUnsentChangesIsNamedUntilItIsBack() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    await harness.manager.setPending(domain, true)
    // A connected location shows its own pending files in Finder: no row.
    #expect(await waiting(harness).isEmpty)

    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.barrier(after: 2)
    #expect(await waiting(harness) == ["Phone"])

    await harness.transport.attach(await makeDevice("A"))
    harness.tick()
    _ = await harness.manager.waitForCalls(5)
    #expect(await waiting(harness).isEmpty)
  }

  /// Once the changes are sent the row goes, whether or not the location is shown yet.
  @Test func aLocationWhoseChangesAreSentIsNotNamed() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    await harness.manager.setPending(domain, true)
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.barrier(after: 2)
    #expect(await waiting(harness) == ["Phone"])

    await harness.manager.setPending(domain, false)
    #expect(await waiting(harness).isEmpty)
  }

  /// A location from before the agent started, whose device is away, is named by the name the
  /// system has for it.
  @Test func anAdoptedLocationIsNamedByItsSystemName() async throws {
    let gone = DomainNaming.identifier(
      for: StorageID(device: DeviceID(serial: "GONE"), key: internalKey))
    let manager = FakeDomainManager(existing: [gone])
    await manager.setPending(gone, true)
    await manager.setDisplayName(gone, "LinkRunner-100G")
    let harness = try AgentHarness(manager: manager)
    defer { harness.finish() }
    _ = await harness.barrier(after: 1)
    #expect(await waiting(harness) == ["LinkRunner-100G"])
  }

  /// The device moves to ADB: its MTP card location is hidden with changes in it, and is named
  /// while the device is served the other way; moving back to MTP clears it.
  @Test func theOldCardLocationIsNamedAfterAMethodChange() async throws {
    let cards = DomainControllerCardTests()
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [try await cards.mtp()], adb: adbTransport)
    defer { harness.finish() }
    let mtpCard = DomainControllerCardTests.oldCardDomain
    let adbCard = DomainControllerCardTests.cardDomain
    _ = await harness.manager.waitForCalls(2)
    await harness.manager.setPending(mtpCard, true)

    await adbTransport.attach(try await cards.adb())
    harness.tick()
    _ = await harness.manager.waitUntil {
      $0.hidden == [mtpCard] && $0.registered.contains(adbCard)
    }
    #expect(await waiting(harness) == ["LinkRunner-100G – SD card"])

    await adbTransport.detach(DomainControllerCardTests.id)
    harness.tick()
    _ = await harness.manager.waitUntilHidden([adbCard])
    #expect(await waiting(harness).isEmpty)
  }
}
