import DeviceKit
import Foundation
import Testing
import os

@testable import ADBTransport

/// A network route is served only when the agent's policy allows that adb serial for the device
/// it answers as; USB routes are never asked.
struct ADBTransportServingTests {
  typealias Fixture = TransportFixture

  @Test func aNetworkRouteThePolicyRefusesIsNotServed() async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerWiFi, device: android)])
    let asked = Box<[String]>([])
    let transport = Fixture.transport(
      port: hub.port,
      serving: { serial, id in
        Task { await asked.set(await asked.value + ["\(serial) \(id.serial)"]) }
        return false
      })
    let scan = try await transport.scan()
    #expect(scan.devices.isEmpty)
    #expect(await transport.routes(for: Fixture.linkRunner) == nil)
    await #expect(throws: TransportError.deviceNotFound(Fixture.linkRunner)) {
      _ = try await transport.open(Fixture.linkRunner)
    }
    #expect(
      try await eventually {
        await asked.value.contains("\(Fixture.linkRunnerWiFi) \(Fixture.linkRunnerSerial)")
      })
  }

  @Test func usbIsServedWhateverThePolicySays() async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([
      .init(Fixture.linkRunnerSerial, device: android),
      .init(Fixture.linkRunnerWiFi, device: android),
    ])
    let transport = Fixture.transport(port: hub.port, serving: { _, _ in false })
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    #expect(
      await transport.routes(for: Fixture.linkRunner)
        == ADBRoutes(usb: Fixture.linkRunnerSerial, wireless: []))
  }

  @Test func aNetworkRouteThePolicyAllowsIsServed() async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerWiFi, device: android)])
    let transport = Fixture.transport(port: hub.port, serving: { _, _ in true })
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
  }

  /// A route the policy stops serving (its device got a Finder location after a terminal
  /// `adb connect`) still carries the session already open on it, and the tools follow that
  /// session, as the files do, until it ends.
  @Test func theOpenSessionsRouteOutlastsThePolicy() async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerWiFi, device: android)])
    let serving = OSAllocatedUnfairLock(initialState: true)
    let transport = Fixture.transport(
      port: hub.port, serving: { _, _ in serving.withLock { $0 } })
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    #expect(await transport.sessionRoute(for: Fixture.linkRunner) == nil)
    let session = try await transport.open(Fixture.linkRunner)
    #expect(await transport.sessionRoute(for: Fixture.linkRunner) == Fixture.linkRunnerWiFi)
    serving.withLock { $0 = false }
    _ = try await transport.scan()
    #expect(await transport.routes(for: Fixture.linkRunner) == nil)
    #expect(await transport.sessionRoute(for: Fixture.linkRunner) == Fixture.linkRunnerWiFi)
    await session.close()
    #expect(await transport.sessionRoute(for: Fixture.linkRunner) == nil)
    await hub.kill()
  }
}
