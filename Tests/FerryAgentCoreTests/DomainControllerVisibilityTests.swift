import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The mend that ends every reconcile compares the system's own hidden state, so a difference
/// heals whatever caused it.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerVisibilityTests {
  /// The system hides a served device's location behind Ferry's back: the next reconcile shows
  /// it again.
  @Test func aServedLocationTheSystemHidIsShownAgain() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    await harness.manager.drift(domain, hidden: true)
    _ = await harness.barrier(after: 1)
    #expect(await harness.manager.waitUntilHidden([]).isEmpty)
  }

  /// While the hidden domains cannot be listed, every domain is set again as it should be.
  @Test func aFailedListingSetsEveryDomainAgain() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    await harness.manager.drift(domain, hidden: true)
    await harness.manager.failHiddenListing(1)
    _ = await harness.barrier(after: 1)
    #expect(await harness.manager.waitUntilHidden([]).isEmpty)
  }

  /// A hide that keeps failing is tried again on a timer, with no hub event to prompt it, as at
  /// a start with no device.
  @Test func aFailedHideIsRetriedOnATimer() async throws {
    let gone = DomainNaming.identifier(
      for: StorageID(device: DeviceID(serial: "GONE"), key: internalKey))
    let manager = FakeDomainManager(existing: [gone])
    // Adoption's own hide, then the retry's first try.
    await manager.failVisibility(2)
    let harness = try AgentHarness(manager: manager)
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let events = await harness.controller.handledEvents

    await harness.retryClock.waitForSleeper()
    await harness.retryClock.advance(by: DomainController.visibilityRetry)
    // The first retry failed too: the next waits twice as long.
    await harness.retryClock.waitForSleeper()
    await harness.retryClock.advance(by: DomainController.visibilityRetry * 2)
    #expect(await harness.manager.waitUntilHidden([gone]) == [gone])
    #expect(await harness.controller.handledEvents == events)
  }
}
