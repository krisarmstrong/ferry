import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// An open session, and the tools that follow it, stay on the adb connection they opened on:
/// when adb reconnects the address to another unit (DHCP gave it away), they fail rather than
/// reach that unit, even before any scan notices.
@Suite(.timeLimit(.minutes(1)))
struct ADBTransportPinningTests {
  typealias Fixture = TransportFixture
  static let address = "192.0.2.5:5555"
  static let first = DeviceID(serial: "0123456789abcdef")

  @Test func aSessionAndItsToolsNeverReachTheNextUnitAtTheAddress() async throws {
    let unitA = Fixture.android(serial: "0123456789abcdef")
    unitA.addFile("/a.txt", Data("A".utf8))
    let unitB = Fixture.android(serial: "fedcba9876543210")
    unitB.addFile("/b.txt", Data("B".utf8))
    let hub = try await Fixture.hub([.init(Self.address, device: unitA, transportID: 1)])
    let transport = Fixture.transport(port: hub.port)
    #expect(try await transport.scan().devices.map(\.id) == [Self.first])
    let session = try await transport.open(Self.first)
    let route = try #require(await transport.sessionRoute(for: Self.first))
    let storage = StorageID(device: Self.first, key: StorageKey.internal)

    // adb reconnects the address; the unit there now is B. No scan has run.
    hub.set([.init(Self.address, device: unitB, transportID: 2)])

    var listed: [String] = []
    do {
      listed = try await session.list(.root, in: storage).compactMap(\.path.name)
    } catch {}
    #expect(!listed.contains("b.txt"))
    var reached: String?
    do {
      reached = try await transport.deviceTools.deviceInfo(route: route).serial
    } catch {}
    #expect(reached != "fedcba9876543210")
    #expect(unitB.state.withLock { $0.tools.services }.isEmpty)
    await session.close()
    await hub.kill()
  }

  /// Once the session it opened has ended, the route is gone, and a scan names the new unit.
  @Test func theNextScanAdoptsTheNewUnitOnceTheSessionHasEnded() async throws {
    let unitA = Fixture.android(serial: "0123456789abcdef")
    let unitB = Fixture.android(serial: "fedcba9876543210")
    let hub = try await Fixture.hub([.init(Self.address, device: unitA, transportID: 1)])
    let transport = Fixture.transport(port: hub.port)
    _ = try await transport.scan()
    let session = try await transport.open(Self.first)
    hub.set([.init(Self.address, device: unitB, transportID: 2)])
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await session.storages()
    }
    #expect(await transport.sessionRoute(for: Self.first) == nil)
    #expect(
      try await transport.scan().devices.map(\.id) == [DeviceID(serial: "fedcba9876543210")])
    await hub.kill()
  }

  /// The tools have no route to a session that is still opening.
  @Test func noRouteWhileTheSessionOpens() async throws {
    let unitA = Fixture.android(serial: "0123456789abcdef")
    let hub = try await Fixture.hub([.init(Self.address, device: unitA, transportID: 1)])
    let transport = Fixture.transport(port: hub.port)
    _ = try await transport.scan()
    let seen = Box<ADBRoute?>(ADBRoute(serial: "unset"))
    unitA.state.withLock {
      $0.beforeFeatures = { await seen.set(await transport.sessionRoute(for: Self.first)) }
    }
    let session = try await transport.open(Self.first)
    #expect(await seen.value == nil)
    #expect(
      await transport.sessionRoute(for: Self.first)
        == ADBRoute(serial: Self.address, transportID: "1"))
    await session.close()
    await hub.kill()
  }

  /// A tool that took the route while A's session was open, and connects only after A is
  /// released and a scan has seen B at the address, still fails rather than reaching B.
  @Test func aRouteTakenEarlierNeverReachesTheNextUnit() async throws {
    let unitA = Fixture.android(serial: "0123456789abcdef")
    let unitB = Fixture.android(serial: "fedcba9876543210")
    let hub = try await Fixture.hub([.init(Self.address, device: unitA, transportID: 1)])
    let transport = Fixture.transport(port: hub.port)
    _ = try await transport.scan()
    let session = try await transport.open(Self.first)
    let route = try #require(await transport.sessionRoute(for: Self.first))
    await session.close()
    hub.set([.init(Self.address, device: unitB, transportID: 2)])
    _ = try await transport.scan()
    let servicesBefore = unitB.state.withLock { $0.tools.services }
    var reached: String?
    do {
      reached = try await transport.deviceTools.deviceInfo(route: route).serial
    } catch {}
    #expect(reached != "fedcba9876543210")
    #expect(unitB.state.withLock { $0.tools.services } == servicesBefore)
    await hub.kill()
  }
}
