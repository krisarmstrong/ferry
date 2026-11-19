import Foundation
import Testing
import os

@testable import ADBTransport

actor Box<Value: Sendable> {
  private(set) var value: Value
  init(_ value: Value) { self.value = value }
  func set(_ new: Value) { value = new }
}

/// A loopback port that refuses connections for as long as this object lives.
///
/// A socket that is bound but not listening cannot do this: macOS drops the SYN and a connect
/// hangs for about eight seconds instead of being refused. So the port is picked, not held:
/// it is outside the kernel's ephemeral range (49152 and up), so no outgoing connection is ever
/// given it, and outside the range `FakeADBServer` picks from (30000 to 39999); a
/// process-wide registry hands each caller a different one, so no two tests share it; and a
/// bind with no address reuse must succeed, which proves nothing else on the machine holds it.
/// The registry entry is released on `deinit`.
final class ClosedPort: Sendable {
  private static let taken = OSAllocatedUnfairLock(initialState: Set<UInt16>())
  let port: UInt16

  init() throws {
    for _ in 0..<1000 {
      let candidate = UInt16.random(in: 20_000..<30_000)
      guard Self.taken.withLock({ $0.insert(candidate).inserted }) else { continue }
      if Self.isFree(candidate) {
        port = candidate
        return
      }
      Self.taken.withLock { _ = $0.remove(candidate) }
    }
    throw POSIXError(.EADDRINUSE)
  }

  deinit { _ = Self.taken.withLock { $0.remove(port) } }

  /// True if a fresh socket can bind the port: nothing is listening or holding it.
  private static func isFree(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    address.sin_port = port.bigEndian
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }
}

/// Polls until `condition` holds, up to `timeout`: waiting on what a test needs rather than
/// sleeping a guess at how long a loaded machine takes.
func eventually(
  timeout: Duration = .seconds(10), _ condition: () async -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
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

  @Test func hardCodedReplyBytesParse() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.send("OKAY00040029")
    }
    defer { server.stop() }
    #expect(try await host(server).version() == 0x29)
  }

  @Test func hardCodedFailBytesParse() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.send("FAIL0004nope")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.failed("nope")) { _ = try await host(server).devices() }
  }

  @Test func framingMatchesTheProtocolSpec() throws {
    #expect(try ADBWire.frame("host:version") == Data("000chost:version".utf8))
    #expect(try ADBWire.length(of: Data("00ff".utf8)) == 255)
    #expect(throws: ADBError.self) { try ADBWire.length(of: Data("00zz".utf8)) }
  }

  @Test func peerCloseIsConnectionClosed() async throws {
    let server = try await FakeADBServer.start { peer in _ = try await peer.request() }
    defer { server.stop() }
    await #expect(throws: ADBError.connectionClosed) { _ = try await host(server).version() }
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
          model: "LinkRunner_100G", product: "LinkRunner-100G", transportID: "1"),
        ADBDevice(
          serial: "R58M12ABCDE", state: .unauthorized, isWireless: false, transportID: "2"),
        ADBDevice(
          serial: "192.168.1.20:5555", state: .device, isWireless: true, model: "Pixel_4a",
          product: "sunfish", transportID: "3"),
        ADBDevice(serial: "emulator-5554", state: .offline, isWireless: true, transportID: "4"),
      ])
  }

  @Test func unfamiliarStateIsKept() {
    let devices = ADBWire.devices(from: "abc recovery usb:1-1 transport_id:1\n")
    #expect(
      devices == [
        ADBDevice(serial: "abc", state: .other("recovery"), isWireless: false, transportID: "1")
      ])
  }

  /// adb marks a USB device with `usb:`; anything without it (network, mDNS, an emulator) is not
  /// on a cable and must not outrank one.
  @Test func onlyAnEntryWithAUSBPathIsOnUSB() {
    let devices = ADBWire.devices(
      from: "abc device usb:1-1 transport_id:1\nemulator-5554 device transport_id:2\n")
    #expect(devices.map(\.isWireless) == [false, true])
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
    let closed = try ClosedPort()
    await #expect(throws: ADBError.serverUnavailable) {
      _ = try await ADBHost(port: closed.port, locator: Self.noAdb).version()
    }
    withExtendedLifetime(closed) {}
  }

  @Test func stopAndWaitReturnsForAnAlreadyStoppedListener() async throws {
    let server = try await FakeADBServer.start { _ in }
    server.stop()
    let returned = Box(false)
    let waiter = Task {
      await server.stopAndWait()
      await server.stopAndWait()
      await returned.set(true)
    }
    defer { waiter.cancel() }
    #expect(try await eventually { await returned.value })
  }

  @Test func startServerWithoutAdbIsNotInstalled() async {
    await #expect(throws: ADBError.adbNotInstalled) {
      try await ADBHost(port: 1, locator: Self.noAdb).startServer()
    }
  }

  @Test func requestLengthLimitIsFourHexDigitsOfUTF8Bytes() throws {
    #expect(throws: ADBError.protocolViolation("request of 65536 bytes exceeds the 4-digit length"))
    {
      try ADBWire.frame(String(repeating: "x", count: 0x10000))
    }
    let widest = try ADBWire.frame(String(repeating: "x", count: 0xFFFF))
    #expect(widest.prefix(4) == Data("ffff".utf8))
    #expect(widest.count == 0xFFFF + 4)
    // 3 bytes per character: 21,846 of them is 65,538 bytes.
    #expect(throws: ADBError.self) {
      try ADBWire.frame(String(repeating: "\u{20AC}", count: 21_846))
    }
    #expect(try ADBWire.frame("\u{20AC}").prefix(4) == Data("0003".utf8))
  }

  @Test func invalidRequestNeverOpensASocket() async throws {
    let connections = Box(0)
    let server = try await FakeADBServer.start { _ in
      await connections.set(await connections.value + 1)
    }
    defer { server.stop() }
    await #expect(throws: ADBError.self) {
      _ = try await host(server).features(String(repeating: "x", count: 70_000))
    }
    await #expect(throws: ADBError.self) {
      _ = try await host(server).connect(String(repeating: "x", count: 70_000), service: "sync:")
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await connections.value == 0)
  }
}
