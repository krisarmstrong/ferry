import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

/// The `adb` invocations Ferry makes, recorded instead of run.
final class FakeADBRunner: Sendable {
  private let calls = Box<[[String]]>([])
  private let reply: @Sendable ([String]) -> ADBCommandResult

  init(reply: @escaping @Sendable ([String]) -> ADBCommandResult) {
    self.reply = reply
  }

  convenience init(output: String, status: Int32 = 0) {
    self.init { _ in ADBCommandResult(status: status, output: output) }
  }

  var run: ADBCommandRunner {
    { [calls, reply] (arguments) async throws(ADBError) in
      await calls.set(await calls.value + [arguments])
      return reply(arguments)
    }
  }

  var invocations: [[String]] {
    get async { await calls.value }
  }
}

struct ADBWirelessTests {
  static let etherScope = WirelessEndpoint(parsing: "192.0.2.31")!
  static let code = PairingCode("482913")!

  /// A server that answers `host:version` and lists `listing` for `host:devices-l`.
  static func server(listing: String) async throws -> FakeADBServer {
    try await FakeADBServer.start { peer in
      switch try await peer.request() {
      case "host:version": try await peer.answer("0029")
      case "host:devices-l": try await peer.answer(listing)
      case let other: try await peer.fail("unexpected \(other)")
      }
    }
  }

  static func wireless(_ server: FakeADBServer, _ runner: FakeADBRunner) -> ADBWireless {
    ADBWireless(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), run: runner.run,
      answerLimit: ADBTransport.defaultAnswerLimit,
      keeper: ADBServerKeeperTests.idle(), clock: ManualClock())
  }

  @Test func argumentArraysAreTheOnlyCommandsBuilt() {
    #expect(ADBCommand.connect(Self.etherScope) == ["connect", "192.0.2.31:5555"])
    #expect(ADBCommand.disconnect(Self.etherScope) == ["disconnect", "192.0.2.31:5555"])
    let pairing = WirelessEndpoint(parsing: "[fe80::1]:37123")!
    #expect(ADBCommand.pair(pairing, Self.code) == ["pair", "[fe80::1]:37123", "482913"])
  }

  @Test func aListedDeviceIsConnected() async throws {
    let server = try await Self.server(
      listing: "192.0.2.31:5555 device product:etherscope_nxg model:EtherScope_nXG\n")
    defer { server.stop() }
    let runner = FakeADBRunner(output: "connected to 192.0.2.31:5555\n")
    let outcome = try await Self.wireless(server, runner).connect(Self.etherScope)
    #expect(outcome == .connected(serial: "192.0.2.31:5555"))
    #expect(await runner.invocations == [["connect", "192.0.2.31:5555"]])
  }

  /// The spike: the first connect says `failed to authenticate` and adb lists the address as
  /// unauthorised until the user taps Allow on the unit.
  @Test(arguments: [
    ("192.0.2.31:5555 unauthorized\n", "failed to authenticate to 192.0.2.31:5555\n"),
    ("", "failed to authenticate to 192.0.2.31:5555\n"),
    ("192.0.2.31:5555 unauthorized\n", "connected to 192.0.2.31:5555\n"),
  ])
  func unauthorisedWaitsForAllow(listing: String, output: String) async throws {
    let server = try await Self.server(listing: listing)
    defer { server.stop() }
    let outcome = try await Self.wireless(server, FakeADBRunner(output: output))
      .connect(Self.etherScope)
    #expect(outcome == .awaitingAllow)
  }

  /// adb exits 0 even when it could not connect: the list decides, adb's words are the detail.
  @Test func aRefusedConnectFailsWithAdbsWords() async throws {
    let server = try await Self.server(listing: "")
    defer { server.stop() }
    let outcome = try await Self.wireless(
      server,
      FakeADBRunner(output: "failed to connect to '192.0.2.31:5555': Connection refused\n")
    ).connect(Self.etherScope)
    #expect(outcome == .failed("failed to connect to '192.0.2.31:5555': Connection refused"))
  }

  /// Without a server, `adb connect` would start one that holds its output open: Ferry asks
  /// the server first and never runs adb when it does not answer.
  @Test func noServerRunsNothing() async throws {
    let closed = try ClosedPort()
    let runner = FakeADBRunner(output: "connected\n")
    let wireless = ADBWireless(
      host: ADBHost(port: closed.port, locator: ADBHostTests.noAdb), run: runner.run,
      answerLimit: ADBTransport.defaultAnswerLimit,
      keeper: ADBServerKeeperTests.idle(), clock: ManualClock())
    await #expect(throws: ADBError.serverUnavailable) {
      _ = try await wireless.connect(Self.etherScope)
    }
    await #expect(throws: ADBError.serverUnavailable) {
      _ = try await wireless.pair(Self.etherScope, code: Self.code)
    }
    #expect(await runner.invocations.isEmpty)
  }

  @Test func pairingReportsTheGuidAdbPrints() async throws {
    let server = try await Self.server(listing: "")
    defer { server.stop() }
    let endpoint = WirelessEndpoint(parsing: "192.0.2.170:37123")!
    let runner = FakeADBRunner(
      output: "Successfully paired to 192.0.2.170:37123 [guid=adb-fedcba9876543210-AbCdEf]\n")
    let outcome = try await Self.wireless(server, runner).pair(endpoint, code: Self.code)
    #expect(outcome == .paired(guid: "adb-fedcba9876543210-AbCdEf"))
    #expect(await runner.invocations == [["pair", "192.0.2.170:37123", "482913"]])
  }

  @Test func aWrongCodeFails() async throws {
    let server = try await Self.server(listing: "")
    defer { server.stop() }
    let outcome = try await Self.wireless(
      server,
      FakeADBRunner(output: "Failed: Wrong password or connection was dropped.\n", status: 1)
    ).pair(Self.etherScope, code: Self.code)
    #expect(outcome == .failed("Failed: Wrong password or connection was dropped."))
  }

  @Test func disconnectRunsDisconnect() async throws {
    let server = try await Self.server(listing: "")
    defer { server.stop() }
    let runner = FakeADBRunner(output: "disconnected 192.0.2.31:5555\n")
    try await Self.wireless(server, runner).disconnect(Self.etherScope)
    #expect(await runner.invocations == [["disconnect", "192.0.2.31:5555"]])
  }

  /// adb's detail is cut to one bounded line before it goes anywhere.
  @Test func failureDetailIsOneBoundedLine() {
    let long = String(repeating: "x", count: 1000)
    #expect(ADBWireless.detail("first\nsecond\n") == "first")
    #expect(ADBWireless.detail(long).count == 200)
    #expect(ADBWireless.detail("\n\n") == "")
  }

  @Test func mdnsServicesAreReadFromTheHostQuery() async throws {
    let lines = [
      "adb-fedcba9876543210-AbCdEf\t_adb-tls-connect._tcp\t192.0.2.170:41235",
      "adb-fedcba9876543210-AbCdEf\t_adb-tls-pairing._tcp.\t192.0.2.170:37123",
      "evil\t_adb-tls-connect._tcp\t-s:5555",
      "junk line",
    ]
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:mdns:services")
      try await peer.send(
        "OKAY" + String(data: ADBWire.frame(lines.joined(separator: "\n") + "\n"), encoding: .utf8)!
      )
    }
    defer { server.stop() }
    let services = try await Self.wireless(server, FakeADBRunner(output: "")).mdnsServices()
    #expect(
      services == [
        ADBMDNSService(
          name: "adb-fedcba9876543210-AbCdEf", type: "_adb-tls-connect._tcp",
          endpoint: WirelessEndpoint(parsing: "192.0.2.170:41235")!),
        ADBMDNSService(
          name: "adb-fedcba9876543210-AbCdEf", type: "_adb-tls-pairing._tcp",
          endpoint: WirelessEndpoint(parsing: "192.0.2.170:37123")!),
      ])
  }

  /// `ip -4 addr` as the EtherScope nXG prints it (2026-11-18): eth0, wlan0 and eno0 count;
  /// `lo` and `dummy0` (10.11.12.13, on both NetAlly units) never do.
  static let etherScopeAddresses = """
    1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1
        inet 127.0.0.1/8 scope host lo
           valid_lft forever preferred_lft forever
    2: dummy0: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN group default qlen 1000
        inet 10.11.12.13/30 brd 10.11.12.15 scope global dummy0
           valid_lft forever preferred_lft forever
    3: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
        inet 192.0.2.31/24 brd 192.0.2.255 scope global eth0
           valid_lft forever preferred_lft forever
    5: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 3000
        inet 192.0.2.170/24 brd 192.0.2.255 scope global wlan0
           valid_lft forever preferred_lft forever
    7: eno0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
        inet 192.0.2.166/24 brd 192.0.2.255 scope global noprefixroute dynamic eno0
           valid_lft 64177sec preferred_lft 53377sec
    9: tun0: <POINTOPOINT,UP> mtu 1500 qdisc noqueue state UNKNOWN group default qlen 500
        inet 10.8.0.2/24 scope global tun0
    10: eth1@if11: <BROADCAST,MULTICAST,UP> mtu 1500 state UP
        inet 192.168.7.2/24 scope global eth1
    """

  @Test func onlyEthernetAndWiFiAddressesCount() {
    #expect(
      ADBWireless.networkAddresses(fromIPAddr: Self.etherScopeAddresses) == [
        "192.0.2.31", "192.0.2.170", "192.0.2.166", "192.168.7.2",
      ])
  }

  /// The LinkRunner during the spike: its ports had no address, only `dummy0`.
  @Test func aUnitOffTheNetworkHasNoAddresses() {
    let linkRunner = """
      2: dummy0: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500
          inet 10.11.12.13/30 brd 10.11.12.15 scope global dummy0
      3: eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500
      4: eno0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500
      """
    #expect(ADBWireless.networkAddresses(fromIPAddr: linkRunner).isEmpty)
  }

  @Test func addressesAndPortAreReadOnTheDevice() async throws {
    let device = FakeAndroid()
    device.state.withLock {
      $0.addresses = Self.etherScopeAddresses
      $0.properties["service.adb.tcp.port"] = "5555"
    }
    let server = try await device.serve(serial: "fedcba9876543210")
    defer { server.stop() }
    let wireless = Self.wireless(server, FakeADBRunner(output: ""))
    #expect(
      try await wireless.networkAddresses(of: "fedcba9876543210").first == "192.0.2.31")
    #expect(try await wireless.tcpPort(of: "fedcba9876543210") == 5555)
    #expect(device.state.withLock { $0.commands }.contains(["ip", "-4", "addr"]))
  }

  @Test(
    arguments: [("", nil), ("0", nil), ("-1", nil), ("5555", 5555), ("70000", nil)]
      as [(
        String, UInt16?
      )])
  func tcpPortIsSetOnlyWhenPositive(value: String, port: UInt16?) async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.properties["service.adb.tcp.port"] = value }
    let server = try await device.serve(serial: "S")
    defer { server.stop() }
    #expect(try await Self.wireless(server, FakeADBRunner(output: "")).tcpPort(of: "S") == port)
  }

  /// `adb tcpip 5555` as the host protocol carries it, checked against hard-coded bytes.
  @Test func tcpipIsTheHostProtocolsService() async throws {
    let received = Box(Data())
    let server = try await FakeADBServer.start { peer in
      await received.set(try await peer.stream.read(exactly: 4 + 31))
      try await peer.send("OKAY")
      await received.set(await received.value + (try await peer.stream.read(exactly: 4 + 10)))
      try await peer.send("OKAYrestarting in TCP mode port: 5555\n")
    }
    defer { server.stop() }
    try await Self.wireless(server, FakeADBRunner(output: "")).restartInTCPMode(
      "0123456789abcdef", port: 5555)
    #expect(
      await received.value == Data("001fhost:transport:0123456789abcdef000atcpip:5555".utf8))
  }

  @Test func tcpipThatDoesNotRestartFails() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.okay()
      _ = try await peer.request()
      try await peer.send("OKAYerror: device not rooted\n")
    }
    defer { server.stop() }
    await #expect(throws: ADBError.failed("error: device not rooted")) {
      try await Self.wireless(server, FakeADBRunner(output: "")).restartInTCPMode(
        "S", port: 5555)
    }
  }

  @Test func theDeviceBehindAnAddressIsReadFromItsProperties() async throws {
    let device = FakeAndroid()
    device.state.withLock {
      $0.properties = [
        "ro.serialno": "fedcba9876543210", "ro.product.model": "EtherScope nXG",
        "ro.product.manufacturer": "freescale",
      ]
    }
    let server = try await device.serve(serial: "192.0.2.31:5555")
    defer { server.stop() }
    let info = try await Self.wireless(server, FakeADBRunner(output: "")).device(
      at: "192.0.2.31:5555")
    #expect(info?.id == DeviceID(serial: "fedcba9876543210"))
    #expect(info?.model == "EtherScope nXG")
  }
}

struct ADBCommandRunTests {
  /// A stand-in executable that prints its arguments one per line, then exits with status 3.
  static func fakeExecutable(_ body: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ferry-fake-adb-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "adb")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
  }

  @Test(.timeLimit(.minutes(1)))
  func runsTheExecutableWithItsArgumentsAndCapturesOutput() async throws {
    let adb = try Self.fakeExecutable(#"printf '%s\n' "$@"; echo err >&2; exit 3"#)
    defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
    let result = try await ADBCommand.run(
      adb, ["connect", "a b;$(x)'"], limit: .seconds(20))
    #expect(result.status == 3)
    // One argument, delivered intact: nothing parsed it as shell.
    #expect(result.output.contains("connect\na b;$(x)'\n"))
    #expect(result.output.contains("err"))
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandThatDoesNotFinishIsStopped() async throws {
    let adb = try Self.fakeExecutable("exec sleep 30")
    defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
    let started = ContinuousClock.now
    await #expect(throws: ADBError.self) {
      _ = try await ADBCommand.run(adb, ["connect"], limit: .milliseconds(300))
    }
    #expect(started.duration(to: .now) < .seconds(10))
  }

  @Test(.timeLimit(.minutes(1)))
  func outputIsBounded() async throws {
    let adb = try Self.fakeExecutable("head -c 200000 /dev/zero | tr '\\0' x")
    defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
    let result = try await ADBCommand.run(adb, [], limit: .seconds(20))
    #expect(result.output.utf8.count <= ADBCommand.outputLimit)
  }

  @Test func noAdbIsNotInstalled() async {
    let run = ADBCommand.runner(locator: ADBHostTests.noAdb)
    await #expect(throws: ADBError.adbNotInstalled) { _ = try await run(["connect", "x:1"]) }
  }

  @Test func aNonDefaultServerPortIsPassedFirst() {
    #expect(ADBCommand.arguments(["connect", "x:1"], port: 5037) == ["connect", "x:1"])
    #expect(
      ADBCommand.arguments(["connect", "x:1"], port: 6000) == ["-P", "6000", "connect", "x:1"])
  }
}

struct ADBServerEventTests {
  /// A wireless reconnect is due when the server comes back, which a list of no devices
  /// cannot say on its own.
  @Test(.timeLimit(.minutes(1)))
  func trackingSaysWhenTheServerIsGone() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.okay()
      try await peer.send(String(data: ADBWire.frame("abc device usb:1-1\n"), encoding: .utf8)!)
    }
    let host = ADBHost(
      port: server.port, locator: ADBHostTests.noAdb, launcher: { _ in },
      backoff: Backoff(initial: .milliseconds(50), maximum: .milliseconds(50)))
    var events: [ADBServerEvent] = []
    for await event in host.trackServer() {
      events.append(event)
      if events.count == 2 { break }
    }
    server.stop()
    #expect(
      events == [
        .devices([ADBDevice(serial: "abc", state: .device, isWireless: false)]), .unavailable,
      ])
  }
}
