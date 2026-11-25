import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A request refused because the phone was locked is `.notAuthenticated` to FileProvider, which
/// then holds the domain's work until told the cause is gone. Unlocking the phone must tell it,
/// or a copy stopped by the lock stalls after the unlock.
@Suite(.timeLimit(.minutes(1)))
struct AgentLockResolvedTests {
  private func lockResolved(_ manager: FakeDomainManager, _ domain: String) async -> Bool {
    await manager.calls.contains(.lockResolved(domain))
  }

  @Test func unlockingAfterARefusalTellsFileProvider() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    await device.setLocked(true)
    let refused = await harness.service.handle(
      .list(domain: domain, folder: .root), file: nil)
    #expect(refused == .failure(.deviceLocked))
    #expect(await harness.manager.waitUntilHidden([domain]) == [domain])
    #expect(await lockResolved(harness.manager, domain) == false)

    await device.setLocked(false)
    _ = await harness.service.handle(.recheck(device.info.id), file: nil)
    await harness.manager.waitFor(.lockResolved(domain))
    #expect(await lockResolved(harness.manager, domain))
  }

  /// Locked only in passing: the device answers again by the time it is read, so FileProvider
  /// is told at once.
  @Test func aLockInPassingIsResolvedAtOnce() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    await device.failList(with: .deviceLocked)
    let refused = await harness.service.handle(
      .list(domain: domain, folder: .root), file: nil)

    #expect(refused == .failure(.deviceLocked))
    #expect(await lockResolved(harness.manager, domain))
  }

  /// Nothing to resolve when nothing was refused.
  @Test func anOrdinaryRequestResolvesNothing() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    #expect(
      await harness.service.handle(.list(domain: domain, folder: .root), file: nil)
        != .failure(.deviceLocked))
    #expect(await lockResolved(harness.manager, domain) == false)
  }
}
