import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// What the agent tells the app about adb: whether it can be used, which devices wait for the
/// user to allow USB debugging, and the "Check again" request.
@Suite(.timeLimit(.minutes(1)))
struct AgentADBStatusTests {
  private func report(_ harness: AgentHarness) async throws -> StatusReport {
    guard case .status(let report) = await harness.service.handle(.status, file: nil) else {
      throw TransportError.io("no status")
    }
    return report
  }

  @Test func statusCarriesWhatAdbReports() async throws {
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.setADBStatus(.notInstalled)
    let harness = try AgentHarness(adb: adb)
    defer { harness.finish() }
    #expect(try await report(harness).adbStatus == .notInstalled)
    #expect(try await report(harness).awaitingUSBDebugging.isEmpty)
  }

  @Test func statusHasNoAdbStatusWithoutAdb() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    #expect(try await report(harness).adbStatus == nil)
  }

  /// MTP serves the device, so adb's own entry for it is left out of the device list; the
  /// report still says USB debugging waits for the user.
  @Test func statusNamesADeviceWaitingForUSBDebugging() async throws {
    let device = await makeDevice("A")
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.requireUSBDebuggingAllow(device.info.id)
    let harness = try AgentHarness(devices: [device], adb: adb)
    defer { harness.finish() }
    let status = try await report(harness)
    #expect(status.awaitingUSBDebugging == [device.info.id])
    #expect(status.devices.map(\.id) == [device.info.id])
    #expect(status.devices.first?.method == .usbFileTransfer)
  }

  @Test func recheckStartsTheServerAndScansAgain() async throws {
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.setADBStatus(.notInstalled)
    await adb.setADBStatusAfterStart(.available)
    let harness = try AgentHarness(adb: adb)
    defer { harness.finish() }
    #expect(try await report(harness).adbStatus == .notInstalled)
    #expect(await harness.service.handle(.recheckADB, file: nil) == .done)
    #expect(await adb.serverStarts == 1)
    #expect(try await report(harness).adbStatus == .available)
  }

  @Test func recheckWithoutAdbIsHarmless() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    #expect(await harness.service.handle(.recheckADB, file: nil) == .done)
  }

  /// A request that takes no file is refused with one, as every other is.
  @Test func recheckTakesNoFile() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let file = try harness.readable("x", "x")
    #expect(
      await harness.service.handle(.recheckADB, file: file)
        == .failure(.io(String(localized: AgentText.badRequest))))
  }
}
