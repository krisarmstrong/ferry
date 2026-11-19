import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

struct ADBWirelessLimitTests {
  /// A device or server that stops answering costs each call `answerLimit`, never forever:
  /// the agent holds its Wi-Fi gate across these calls.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["devices", "connect", "mdns", "device", "tcpPort", "addresses", "tcpip"])
  func everyAnswerIsBounded(_ call: String) async throws {
    let server = try await FakeADBServer.start { peer in
      let request = try await peer.request()
      if request == "host:version", call == "connect" {
        try await peer.answer("0029")
        return
      }
      if request.hasPrefix("host:transport:") {
        try await peer.okay()
        _ = try await peer.request()
        try await peer.okay()
      }
      // Answers nothing more until the client gives up.
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let wireless = ADBWireless(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb),
      run: FakeADBRunner(output: "connected to 192.0.2.31:5555\n").run,
      answerLimit: .milliseconds(200))
    let serial = "192.0.2.31:5555"
    let error = await #expect(throws: ADBError.self) {
      switch call {
      case "devices": _ = try await wireless.devices()
      case "connect": _ = try await wireless.connect(WirelessEndpoint(parsing: serial)!)
      case "mdns": _ = try await wireless.mdnsServices()
      case "device": _ = try await wireless.device(at: serial)
      case "tcpPort": _ = try await wireless.tcpPort(of: serial)
      case "addresses": _ = try await wireless.networkAddresses(of: serial)
      default: try await wireless.restartInTCPMode(serial, port: 5555)
      }
    }
    guard case .failed(let detail) = error else {
      Issue.record("not a timeout: \(String(describing: error))")
      return
    }
    #expect(detail.hasPrefix("no answer within"))
  }
}
