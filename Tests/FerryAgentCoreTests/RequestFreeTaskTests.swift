import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Hub work started while a request is handled belongs to no request: a cancelled request's
/// turn, which refuses every device call, must not follow it into the hub's tasks.
@Suite(.timeLimit(.minutes(1)))
struct RequestFreeTaskTests {
  @Test func aHubTaskStartedByACancelledRequestStillReachesTheDevice() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let before = await device.storagesCallCount
    let cancelled = RequestCancellation()
    cancelled.cancel()

    // A reconcile reads the held device's storages on a task of its own.
    await RequestCancellation.$current.withValue(cancelled) {
      await DeviceTurns.$current.withValue(cancelled) {
        await harness.hub.reconcile()
      }
    }

    #expect(try await eventually { await device.storagesCallCount > before })
    #expect(await harness.hub.devices().map(\.state) == [.ready(try await device.storages())])
  }
}
