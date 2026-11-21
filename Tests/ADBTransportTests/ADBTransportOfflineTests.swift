import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// A server whose first read from a USB device failed at start ("connection terminated: read
/// failed") lists it offline until it is replugged. A USB device offline for longer than a
/// server start takes is reconnected once (`host:reconnect-offline`); one still offline after
/// that is reported, so the menu can ask for a replug. Network devices are WirelessADB's.
@Suite(.timeLimit(.minutes(1)))
struct ADBTransportOfflineTests {
  typealias Fixture = TransportFixture
  static let serial = Fixture.linkRunnerSerial

  @Test func aUSBDeviceStillOfflineIsReconnectedOnceThenReported() async throws {
    let hub = try await Fixture.hub([.init(Self.serial, "offline", device: nil)])
    defer { Task { await hub.kill() } }
    let clock = TestClock()
    let transport = Fixture.transport(port: hub.port, clock: clock)

    var scan = try await transport.scan()
    #expect(hub.reconnects == 0)
    #expect(scan.stuckOffline.isEmpty)
    #expect(scan.rescanAfter != nil)

    clock.advance(by: ADBTransport.offlineGrace)
    scan = try await transport.scan()
    #expect(hub.reconnects == 1)
    #expect(scan.stuckOffline.isEmpty)
    _ = try await transport.scan()
    #expect(hub.reconnects == 1)

    clock.advance(by: ADBTransport.offlineGrace)
    scan = try await transport.scan()
    #expect(hub.reconnects == 1)
    #expect(scan.stuckOffline == [Fixture.linkRunner])
  }

  /// One that comes back ends its episode: going offline again earns another reconnect.
  @Test func aDeviceBackFromOfflineStartsAgain() async throws {
    let hub = try await Fixture.hub([.init(Self.serial, "offline", device: nil)])
    defer { Task { await hub.kill() } }
    hub.reconnectHeals(true)
    let clock = TestClock()
    let transport = Fixture.transport(port: hub.port, clock: clock)
    _ = try await transport.scan()
    clock.advance(by: ADBTransport.offlineGrace)
    _ = try await transport.scan()
    #expect(hub.reconnects == 1)
    clock.advance(by: ADBTransport.offlineGrace)
    #expect(try await transport.scan().stuckOffline.isEmpty)

    hub.set([.init(Self.serial, "offline", device: nil)])
    _ = try await transport.scan()
    clock.advance(by: ADBTransport.offlineGrace)
    _ = try await transport.scan()
    #expect(hub.reconnects == 2)
  }

  /// A server just started lists a USB device offline for a moment: no reconnect before the
  /// grace, and never one for a network device.
  @Test func shortOfflinesAndNetworkDevicesAreLeftAlone() async throws {
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerWiFi, "offline", device: nil)])
    defer { Task { await hub.kill() } }
    let clock = TestClock()
    let transport = Fixture.transport(port: hub.port, clock: clock)
    _ = try await transport.scan()
    clock.advance(by: ADBTransport.offlineGrace * 3)
    let scan = try await transport.scan()
    #expect(hub.reconnects == 0)
    #expect(scan.stuckOffline.isEmpty)
  }
}
