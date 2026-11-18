import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// A wedged device or server must not stall a scan, nor an open of another device.
struct ADBTransportTimeoutTests {
  typealias Fixture = TransportFixture

  static let limit = Duration.seconds(2)

  @Test func aDeviceThatNeverAnswersIsLeftOutAndBlocksNothing() async throws {
    let good = Fixture.android(serial: "AAAA")
    let wedged = Fixture.android(serial: "BBBB", model: "Wedged")
    wedged.state.withLock { $0.hangingPrograms = ["getprop"] }
    let hub = try await Fixture.hub([.init("AAAA", device: good)])
    let transport = Fixture.transport(port: hub.port, answerLimit: Self.limit)
    #expect(try await transport.scan().devices.map(\.id.serial) == ["AAAA"])

    hub.set([.init("AAAA", device: good), .init("BBBB", device: wedged)])
    let started = ContinuousClock.now
    let scanning = Task { try await transport.scan() }
    try await Task.sleep(for: .milliseconds(100))
    let opened = ContinuousClock.now
    let session = try await transport.open(DeviceID(serial: "AAAA"))
    #expect(opened.duration(to: .now) < .seconds(1))
    let scan = try await scanning.value
    #expect(scan.devices.map(\.id.serial) == ["AAAA"])
    #expect(started.duration(to: .now) < Self.limit + .seconds(3))
    await session.close()

    // Left out uncached: asked again once it answers.
    wedged.state.withLock { $0.hangingPrograms = [] }
    #expect(try await transport.scan().devices.map(\.id.serial) == ["AAAA", "BBBB"])
    await hub.kill()
  }

  @Test func aServerThatNeverAnswersIsServerDownWithinTheLimit() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      _ = try? await peer.stream.read(exactly: 1)
    }
    let transport = Fixture.transport(port: server.port, answerLimit: Self.limit)
    let started = ContinuousClock.now
    #expect(try await transport.scan() == DeviceScan(devices: [], method: .usbADB))
    #expect(started.duration(to: .now) < Self.limit + .seconds(3))
    #expect(await transport.status == .serverDown)
    await server.stopAndWait()
  }

  @Test func aScanCancelledWhileReadingADeviceThrowsCancelled() async throws {
    let wedged = Fixture.android(serial: "BBBB")
    wedged.state.withLock { $0.hangingPrograms = ["getprop"] }
    let hub = try await Fixture.hub([.init("BBBB", device: wedged)])
    let transport = Fixture.transport(port: hub.port)
    let scanning = Task { () -> TransportError? in
      do throws(TransportError) {
        _ = try await transport.scan()
        return nil
      } catch {
        return error
      }
    }
    try await Task.sleep(for: .milliseconds(200))
    scanning.cancel()
    #expect(await scanning.value == .cancelled)
    await hub.kill()
  }
}

/// A device left out because it did not answer is asked again on a schedule of its own: adb
/// sends no event for a list that has not changed.
struct ADBTransportRetryTests {
  typealias Fixture = TransportFixture

  @Test func anUnnamedDeviceAsksForARescanThatBacksOff() async throws {
    let slow = Fixture.android(serial: "BBBB")
    slow.state.withLock { $0.hangingPrograms = ["getprop"] }
    let hub = try await Fixture.hub([.init("BBBB", device: slow)])
    let transport = Fixture.transport(port: hub.port, answerLimit: .seconds(2))
    var scan = try await transport.scan()
    #expect(scan.devices.isEmpty && scan.rescanAfter == ADBTransport.unnamedRetry)
    scan = try await transport.scan()
    #expect(scan.rescanAfter == ADBTransport.unnamedRetry * 2)
    slow.state.withLock { $0.hangingPrograms = [] }
    scan = try await transport.scan()
    #expect(scan.devices.map(\.id.serial) == ["BBBB"] && scan.rescanAfter == nil)
    await hub.kill()
  }

  @Test func theRescanBackOffIsCapped() {
    #expect(ADBTransport.unnamedDelay(afterTries: 1) == ADBTransport.unnamedRetry)
    #expect(ADBTransport.unnamedDelay(afterTries: 40) == ADBTransport.unnamedRetryLimit)
  }
}
