import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The status names the address adb serves each network device on, so the menu shows that one
/// rather than whichever address the device was remembered at first.
@Suite(.timeLimit(.minutes(1)))
struct AgentNetworkAddressTests {
  private func tools(_ scratch: URL, routes: [DeviceID: String]) -> ADBTools {
    ADBTools(
      device: FakeToolDevice(), target: { id in routes[id].map { ADBRoute(serial: $0) } },
      journal: ToolJournal(store: scratch.appending(path: "journal.json")), scratch: scratch)
  }

  /// A `host:port` route is an address; a USB serial and an mDNS name are not.
  @Test(
    arguments: [
      ("192.0.2.31:37123", WirelessEndpoint(parsing: "192.0.2.31:37123")),
      ("0123456789abcdef", nil),
      ("adb-0123456789abcdef-AbCdEf._adb-tls-connect._tcp", nil),
    ] as [(String, WirelessEndpoint?)])
  func aNetworkRouteIsTheAddress(serial: String, address: WirelessEndpoint?) async throws {
    let scratch = try TestScratch.folder("address")
    let id = DeviceID(serial: "A")
    #expect(await tools(scratch, routes: [id: serial]).networkAddress(of: id) == address)
  }

  @Test func aDeviceWithNoRouteHasNoAddress() async throws {
    let scratch = try TestScratch.folder("address")
    #expect(await tools(scratch, routes: [:]).networkAddress(of: DeviceID(serial: "A")) == nil)
  }

  @Test func theStatusCarriesEachDevicesNetworkAddress() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let service = AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch,
      tools: tools(harness.scratch, routes: [device.info.id: "192.0.2.31:5555"]))
    guard case .status(let report) = await service.handle(.status, file: nil) else {
      Issue.record("no status")
      return
    }
    #expect(report.connectedAddresses == [device.info.id: WirelessEndpoint(parsing: "192.0.2.31")!])
  }
}
