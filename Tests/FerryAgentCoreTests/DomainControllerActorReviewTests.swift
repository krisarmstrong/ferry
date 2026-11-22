import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// Actor review: nothing the controller scheduled acts after Remove Ferry.
extension DomainControllerTests {
  /// The system's domains could not be listed at start, so a retry waits. Remove Ferry runs
  /// meanwhile: the retry then adopts nothing and disconnects nothing.
  @Test func aListingRetryDoesNothingAfterRemoveAll() async throws {
    let gone = DeviceID(serial: "GONE")
    let domain = domainID(await makeDevice(gone.serial))
    let manager = FakeDomainManager(existing: [domain], listingFailures: 1)
    let harness = try AgentHarness(manager: manager)
    defer { harness.finish() }
    _ = await harness.controller.location(of: gone)
    await harness.retryClock.waitForSleeper()

    _ = try await harness.controller.removeAll()
    let removed = await manager.calls
    await harness.retryClock.advance(by: DomainController.listingRetry)
    await harness.controller.listingRetryTask?.value

    #expect(await manager.calls == removed)
    #expect(await harness.controller.domains.isEmpty)
  }

  /// Remove Ferry finishes before the failed listing schedules its retry, so there is no retry
  /// to cancel: the retry itself finds the controller retired and adopts nothing.
  @Test func aListingRetryScheduledAfterRemoveAllDoesNothing() async throws {
    let domain = domainID(await makeDevice("GONE"))
    let manager = FakeDomainManager(existing: [domain], listingFailures: 1)
    let (arrivals, ticks) = AsyncStream.makeStream(of: Void.self)
    defer { ticks.finish() }
    let hub = DeviceHub(
      transport: FakeTransport(devices: []), arrivals: arrivals, clock: ManualClock())
    let retryClock = ManualClock()
    let controller = DomainController(
      hub: hub, manager: manager, itemStore: itemStore(), clock: retryClock)
    _ = try await controller.removeAll()
    #expect(await controller.listingRetryTask == nil)

    let running = Task { await controller.run() }
    defer { running.cancel() }
    await retryClock.waitForSleeper()
    let removed = await manager.calls
    await retryClock.advance(by: DomainController.listingRetry)
    await controller.listingRetryTask?.value

    #expect(await manager.calls == removed)
    #expect(await controller.domains.isEmpty)
  }
}
