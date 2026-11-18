import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// The adb server going away and coming back (Review Focus 5), and the hold, park and release
/// rules the hub relies on.
struct ADBTransportLifecycleTests {
  typealias Fixture = TransportFixture

  static func linkRunnerHub() async throws -> (FakeADBHub, FakeAndroid) {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerSerial, device: android)])
    return (hub, android)
  }

  @Test func devicesLeaveWithTheServerAndReturnWithIt() async throws {
    let (hub, _) = try await Self.linkRunnerHub()
    let port = hub.port
    let transport = Fixture.transport(port: port)
    let ticks = Box(0)
    let listener = Task {
      for await _ in transport.arrivals { await ticks.set(await ticks.value + 1) }
    }
    defer { listener.cancel() }
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    #expect(try await eventually { await ticks.value >= 1 })

    await hub.kill()
    #expect(try await transport.scan() == DeviceScan(devices: []))
    #expect(await transport.status == .serverDown)

    let before = await ticks.value
    try await hub.start(port: port)
    // The tracker reconnects on its own and ticks, so the hub scans again.
    #expect(try await eventually { await ticks.value > before })
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    #expect(await transport.status == .available)
    await hub.kill()
  }

  @Test func aHeldDeviceIsListedButNotOpenedTwice() async throws {
    let (hub, android) = try await Self.linkRunnerHub()
    let transport = Fixture.transport(port: hub.port)
    _ = try await transport.scan()
    let session = try await transport.open(Fixture.linkRunner)
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    #expect(await Fixture.open(transport, Fixture.linkRunner).failure == .deviceBusy)
    await session.close()
    let again = try await transport.open(Fixture.linkRunner)
    await again.close()
    #expect(Fixture.lookups(of: "ro.serialno", on: android) == 1)
    await hub.kill()
  }

  @Test func aDeviceNotInTheLastScanIsNotFound() async throws {
    let (hub, _) = try await Self.linkRunnerHub()
    let transport = Fixture.transport(port: hub.port)
    #expect(
      await Fixture.open(transport, Fixture.linkRunner).failure
        == .deviceNotFound(Fixture.linkRunner))
    await hub.kill()
  }

  @Test func aParkedDeviceIsEjectedUntilUnparkedOrGone() async throws {
    let (hub, android) = try await Self.linkRunnerHub()
    let transport = Fixture.transport(port: hub.port)
    _ = try await transport.scan()
    let session = try await transport.open(Fixture.linkRunner)
    await transport.park(Fixture.linkRunner)
    await session.close()
    var scan = try await transport.scan()
    #expect(scan.devices.isEmpty && scan.ejected == [Fixture.linkRunnerInfo])
    #expect(
      await Fixture.open(transport, Fixture.linkRunner).failure
        == .deviceNotFound(Fixture.linkRunner))

    // A server outage is not an unplug: still ejected once the server is back.
    let port = hub.port
    await hub.kill()
    _ = try await transport.scan()
    try await hub.start(port: port)
    #expect(try await transport.scan().ejected == [Fixture.linkRunnerInfo])

    await transport.unpark(Fixture.linkRunner)
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])

    // Parked again, then unplugged: it mounts when it comes back.
    let reopened = try await transport.open(Fixture.linkRunner)
    await transport.park(Fixture.linkRunner)
    await reopened.close()
    hub.set([])
    scan = try await transport.scan()
    #expect(scan.ejected.isEmpty && scan.devices.isEmpty)
    hub.set([.init(Fixture.linkRunnerSerial, device: android)])
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    await hub.kill()
  }

  @Test func parkingADeviceNotHeldDoesNothing() async throws {
    let (hub, _) = try await Self.linkRunnerHub()
    let transport = Fixture.transport(port: hub.port)
    _ = try await transport.scan()
    await transport.park(Fixture.linkRunner)
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    await hub.kill()
  }

  /// Carried from Task 3 (M6): a server restart mid-session is a disconnect the hub recovers
  /// from by scanning and opening again, not a lasting failure.
  @Test func aServerRestartMidSessionIsADisconnectAndTheDeviceReopens() async throws {
    let (hub, android) = try await Self.linkRunnerHub()
    android.addFile("/a.txt", Data("a".utf8))
    let port = hub.port
    let transport = Fixture.transport(port: port)
    _ = try await transport.scan()
    let session = try await transport.open(Fixture.linkRunner)
    #expect(try await session.storages().map(\.id.key) == ["internal"])

    await hub.kill()
    try await hub.start(port: port)
    let afterRestart = await Fixture.storages(session)
    #expect(afterRestart.failure == .deviceDisconnected, "got \(afterRestart)")
    await session.close()

    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    let reopened = try await transport.open(Fixture.linkRunner)
    #expect(try await reopened.storages().map(\.id.key) == ["internal"])
    await reopened.close()
    await hub.kill()
  }

  @Test func aServerThatStaysDownEndsTheSessionAndReleasesTheDevice() async throws {
    let (hub, _) = try await Self.linkRunnerHub()
    let port = hub.port
    let transport = Fixture.transport(port: port)
    _ = try await transport.scan()
    let session = try await transport.open(Fixture.linkRunner)
    _ = try await session.storages()

    await hub.kill()
    #expect(await Fixture.storages(session).failure == .deviceDisconnected)
    // Released by the disconnect itself, before any close.
    try await hub.start(port: port)
    _ = try await transport.scan()
    let reopened = try await transport.open(Fixture.linkRunner)
    await reopened.close()
    await session.close()
    await hub.kill()
  }
}
