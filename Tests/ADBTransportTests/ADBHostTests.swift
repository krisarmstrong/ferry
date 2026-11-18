import Foundation
import Testing

@testable import ADBTransport

actor Box<Value: Sendable> {
  private(set) var value: Value
  init(_ value: Value) { self.value = value }
  func set(_ new: Value) { value = new }
}

/// A port nothing listens on: a listener's port, after it is closed.
func closedPort() async throws -> UInt16 {
  let server = try await FakeADBServer.start { _ in }
  server.stop()
  try await Task.sleep(for: .milliseconds(50))
  return server.port
}

struct ADBHostTests {
  /// A locator that finds nothing, so a test can never launch a real adb.
  static let noAdb = ADBLocator(
    environment: [:], home: "/nonexistent", isExecutable: { _ in false })

  func host(_ server: FakeADBServer) -> ADBHost {
    ADBHost(port: server.port, locator: Self.noAdb)
  }

  @Test func requestIsFramedWithFourHexDigitLength() async throws {
    let received = Box(Data())
    let server = try await FakeADBServer.start { peer in
      await received.set(try await peer.stream.read(exactly: 16))
      try await peer.answer("0029")
    }
    defer { server.stop() }
    _ = try await host(server).version()
    #expect(await received.value == Data("000chost:version".utf8))
  }

  @Test func versionParsesHexReply() async throws {
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:version")
      try await peer.answer("0029")
    }
    defer { server.stop() }
    #expect(try await host(server).version() == 41)
  }

  @Test func failCarriesServerMessage() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.fail("unknown host service")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.failed("unknown host service")) {
      _ = try await host(server).devices()
    }
  }

  @Test func unknownStatusIsProtocolViolation() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.send("WHAT")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.protocolViolation("unexpected status WHAT")) {
      _ = try await host(server).version()
    }
  }

  @Test func devicesParsesUnauthorizedAndWirelessSerials() async throws {
    let listing = """
      0123456789abcdef       device usb:2162688X product:LinkRunner-100G model:LinkRunner_100G transport_id:1
      R58M12ABCDE            unauthorized usb:1234X transport_id:2
      192.168.1.20:5555      device product:sunfish model:Pixel_4a device:sunfish transport_id:3
      emulator-5554          offline transport_id:4

      """
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:devices-l")
      try await peer.answer(listing)
    }
    defer { server.stop() }
    let devices = try await host(server).devices()
    #expect(
      devices == [
        ADBDevice(
          serial: "0123456789abcdef", state: .device, isWireless: false,
          model: "LinkRunner_100G", product: "LinkRunner-100G"),
        ADBDevice(serial: "R58M12ABCDE", state: .unauthorized, isWireless: false),
        ADBDevice(
          serial: "192.168.1.20:5555", state: .device, isWireless: true, model: "Pixel_4a",
          product: "sunfish"),
        ADBDevice(serial: "emulator-5554", state: .offline, isWireless: false),
      ])
  }

  @Test func unfamiliarStateIsKept() {
    let devices = ADBWire.devices(from: "abc recovery transport_id:1\n")
    #expect(devices == [ADBDevice(serial: "abc", state: .other("recovery"), isWireless: false)])
  }

  @Test func mdnsSerialIsWireless() {
    let devices = ADBWire.devices(from: "adb-XYZ-abc._adb-tls-connect._tcp device\n")
    #expect(devices.first?.isWireless == true)
  }

  @Test func featuresSplitOnCommas() async throws {
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host-serial:abc:features")
      try await peer.answer("cmd,stat_v2,shell_v2")
    }
    defer { server.stop() }
    #expect(try await host(server).features("abc") == ["cmd", "stat_v2", "shell_v2"])
  }

  @Test func missingDeviceIsDeviceGone() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.fail("device 'abc' not found")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.deviceGone("abc")) {
      _ = try await host(server).features("abc")
    }
  }

  @Test func connectSelectsTransportThenServiceAndHandsOverTheSocket() async throws {
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:transport:abc")
      try await peer.okay()
      #expect(try await peer.request() == "sync:")
      try await peer.okay()
      try await peer.send("DONE")
    }
    defer { server.stop() }
    let stream = try await host(server).connect("abc", service: "sync:")
    #expect(try await stream.read(exactly: 4) == Data("DONE".utf8))
    await stream.close()
  }

  @Test func connectToAbsentDeviceIsDeviceGone() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.fail("device 'abc' not found")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.deviceGone("abc")) {
      _ = try await host(server).connect("abc", service: "sync:")
    }
  }

  @Test func refusedConnectionIsServerUnavailable() async throws {
    let port = try await closedPort()
    await #expect(throws: ADBError.serverUnavailable) {
      _ = try await ADBHost(port: port, locator: Self.noAdb).version()
    }
  }

  @Test func startServerWithoutAdbIsNotInstalled() async {
    await #expect(throws: ADBError.adbNotInstalled) {
      try await ADBHost(port: 1, locator: Self.noAdb).startServer()
    }
  }

  @Test func oversizedRequestIsRejected() async {
    await #expect(throws: ADBError.self) {
      _ = try await ADBHost(port: 1, locator: Self.noAdb).features(
        String(repeating: "x", count: 70_000))
    }
  }
}
