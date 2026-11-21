import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

struct ADBWirelessLimitTests {
  /// A device or server that stops answering costs each call its limit, never forever: the
  /// agent holds its Wi-Fi gate across these calls. The limit is measured on a clock the test
  /// moves, once the call waits on it.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "devices", "connect", "pair", "disconnect", "mdns", "device", "tcpPort", "addresses",
      "tcpip",
    ])
  func everyAnswerIsBounded(_ call: String) async throws {
    let server = try await FakeADBServer.start { peer in
      let request = try await peer.request()
      if request.hasPrefix("host:transport:") {
        try await peer.okay()
        _ = try await peer.request()
        try await peer.okay()
      }
      // Answers nothing more until the client gives up.
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let clock = ManualClock()
    let wireless = ADBWireless(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb),
      answerLimit: .seconds(2), commandLimit: .seconds(30),
      keeper: ADBServerKeeperTests.idle(), clock: clock)
    let serial = "192.0.2.31:5555"
    let calling = Task {
      switch call {
      case "devices": _ = try await wireless.devices()
      case "connect": _ = try await wireless.connect(WirelessEndpoint(parsing: serial)!)
      case "pair":
        _ = try await wireless.pair(
          WirelessEndpoint(parsing: serial)!, code: PairingCode("482913")!)
      case "disconnect": try await wireless.disconnect(WirelessEndpoint(parsing: serial)!)
      case "mdns": _ = try await wireless.mdnsServices()
      case "device": _ = try await wireless.device(at: serial)
      case "tcpPort": _ = try await wireless.tcpPort(of: serial)
      case "addresses": _ = try await wireless.networkAddresses(of: serial)
      default: try await wireless.restartInTCPMode(serial, port: 5555)
      }
    }
    // The call's limit is the only wait on this clock; the longest one passes.
    await clock.waitForSleeper()
    await clock.advance(by: .seconds(30))
    let error = await #expect(throws: ADBError.self) { try await calling.value }
    guard case .failed(let detail) = error else {
      Issue.record("not a timeout: \(String(describing: error))")
      return
    }
    #expect(detail.hasPrefix("no answer within"))
  }

  /// The server holds a connect or pair open while it reaches the device, far longer than any
  /// other answer: those requests wait `commandLimit`, not `answerLimit`.
  @Test(.timeLimit(.minutes(1)))
  func connectWaitsTheCommandLimit() async throws {
    let (release, releasing) = AsyncStream.makeStream(of: Void.self)
    let server = try await FakeADBServer.start { peer in
      switch try await peer.request() {
      case "host:devices-l": try await peer.answer("192.0.2.31:5555 device\n")
      default:
        for await _ in release { break }
        try await peer.answer("connected to 192.0.2.31:5555")
      }
    }
    defer { server.stop() }
    let clock = ManualClock()
    let wireless = ADBWireless(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb),
      answerLimit: .seconds(2), commandLimit: .seconds(30),
      keeper: ADBServerKeeperTests.idle(), clock: clock)
    let connecting = Task { try await wireless.connect(WirelessEndpoint(parsing: "192.0.2.31")!) }
    // Past the answer limit, the connect still waits for the server.
    await clock.waitForSleeper()
    await clock.advance(by: .seconds(2))
    releasing.yield()
    #expect(try await connecting.value == .connected(serial: "192.0.2.31:5555"))
  }
}
