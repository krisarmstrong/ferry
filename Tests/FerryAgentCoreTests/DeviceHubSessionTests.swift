import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The hub numbers each session it takes up, and the status carries the numbers: a new number
/// tells the app the device was reached again, even between two of its statuses.
@Suite(.timeLimit(.minutes(1)))
struct DeviceHubSessionTests {
  @Test func aReplugGetsANewSessionNumber() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let first = try #require(await harness.hub.heldSessions()[device.info.id])
    guard case .status(let report) = await harness.service.handle(.status, file: nil) else {
      Issue.record("no status")
      return
    }
    #expect(report.sessions == [device.info.id: first])

    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)
    #expect(await harness.hub.heldSessions().isEmpty)
    await harness.transport.attach(await makeDevice("A"))
    harness.tick()
    _ = await harness.manager.waitForCalls(3)

    let second = try #require(await harness.hub.heldSessions()[device.info.id])
    #expect(second != first)
  }
}
