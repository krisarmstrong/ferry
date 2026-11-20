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
}
