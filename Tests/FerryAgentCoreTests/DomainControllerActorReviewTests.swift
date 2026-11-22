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
}
