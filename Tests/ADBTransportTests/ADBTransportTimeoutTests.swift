import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

/// A wedged device or server must not stall a scan, nor an open of another device. The answer
/// limit is measured on a clock the test moves: a limit passes when the test says so, and never
/// because the machine is busy.
@Suite(.timeLimit(.minutes(1)))
struct ADBTransportTimeoutTests {
  typealias Fixture = TransportFixture

  static let limit = Duration.seconds(2)

  @Test func aDeviceThatNeverAnswersIsLeftOutAndBlocksNothing() async throws {
    let good = Fixture.android(serial: "AAAA")
    let wedged = Fixture.android(serial: "BBBB", model: "Wedged")
    wedged.state.withLock { $0.hangingPrograms = ["getprop"] }
    let hub = try await Fixture.hub([.init("AAAA", device: good)])
    let limits = ManualClock()
    let transport = Fixture.transport(port: hub.port, answerLimit: Self.limit, limits: limits)
    #expect(try await transport.scan().devices.map(\.id.serial) == ["AAAA"])

    hub.set([.init("AAAA", device: good), .init("BBBB", device: wedged)])
    let scanning = Task { try await transport.scan() }
    await wedged.waitForHangs(1)
    // The scan waits on the wedged device, and no time passes: the open cannot be waiting for it.
    let session = try await transport.open(DeviceID(serial: "AAAA"))
    let scan = try await limits.advancing(by: Self.limit) { try await scanning.value }
    #expect(scan.devices.map(\.id.serial) == ["AAAA"])
    await session.close()

    // Left out uncached: asked again once it answers.
    wedged.state.withLock { $0.hangingPrograms = [] }
    #expect(try await transport.scan().devices.map(\.id.serial) == ["AAAA", "BBBB"])
    await hub.kill()
  }

  @Test func aServerThatNeverAnswersIsServerDownAtTheLimit() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      _ = try? await peer.stream.read(exactly: 1)
    }
    let limits = ManualClock()
    let transport = Fixture.transport(port: server.port, answerLimit: Self.limit, limits: limits)
    let scanning = Task { try await transport.scan() }
    // The list query's limit is the only wait on this clock.
    await limits.waitForSleeper()
    await limits.advance(by: Self.limit)
    #expect(
      try await scanning.value
        == DeviceScan(devices: [], method: .usbADB, adbStatus: .serverDown))
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
    await wedged.waitForHangs(1)
    scanning.cancel()
    #expect(await scanning.value == .cancelled)
    await hub.kill()
  }
}

/// A device left out because it did not answer is asked again on a schedule of its own: adb
/// sends no event for a list that has not changed.
@Suite(.timeLimit(.minutes(1)))
struct ADBTransportRetryTests {
  typealias Fixture = TransportFixture

  @Test func anUnnamedDeviceAsksForARescanThatBacksOff() async throws {
    let slow = Fixture.android(serial: "BBBB")
    slow.state.withLock { $0.hangingPrograms = ["getprop"] }
    let hub = try await Fixture.hub([.init("BBBB", device: slow)])
    let limit = Duration.seconds(2)
    let limits = ManualClock()
    let transport = Fixture.transport(port: hub.port, answerLimit: limit, limits: limits)
    /// A scan that the slow device holds up until its answer limit passes.
    func scanPastTheLimit(hang: Int) async throws -> DeviceScan {
      let scanning = Task { try await transport.scan() }
      await slow.waitForHangs(hang)
      return try await limits.advancing(by: limit) { try await scanning.value }
    }
    var scan = try await scanPastTheLimit(hang: 1)
    #expect(scan.devices.isEmpty && scan.rescanAfter == ADBTransport.unnamedRetry)
    scan = try await scanPastTheLimit(hang: 2)
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
