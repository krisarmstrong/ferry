import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

@Suite(.timeLimit(.minutes(1)))
struct ADBWirelessTests {
  static let etherScope = WirelessEndpoint(parsing: "192.0.2.31")!
  static let code = PairingCode("482913")!

  /// A server that answers `host:version`, lists `listing` for `host:devices-l`, answers each
  /// other request from `services`, and records every request it was sent.
  static func server(
    listing: String, services: [String: ServiceReply] = [:], requests: Box<[String]> = Box([])
  ) async throws -> FakeADBServer {
    try await FakeADBServer.start { peer in
      let request = try await peer.request()
      await requests.set(await requests.value + [request])
      switch request {
      case "host:version": try await peer.answer("0029")
      case "host:devices-l": try await peer.answer(listing)
      default:
        switch services[request] {
        case .text(let text): try await peer.answer(text)
        case .failAfterOkay(let reason):
          try await peer.okay()
          try await peer.fail(reason)
        case .plain(let text): try await peer.answer(text)
        case .plainFail(let reason): try await peer.fail(reason)
        case nil: try await peer.fail("unknown host service '\(request)'")
        }
      }
    }
  }

  /// On a clock that never moves: every answer here comes, so no limit is reached.
  static func wireless(
    port: UInt16, opener: @escaping ADBHost.Opener = ADBHost.socketOpener
  ) -> ADBWireless {
    ADBWireless(
      host: ADBHost(port: port, locator: ADBHostTests.noAdb, opener: opener),
      answerLimit: ADBTransport.defaultAnswerLimit, commandLimit: ADBWireless.defaultCommandLimit,
      keeper: ADBServerKeeperTests.idle(), clock: ManualClock())
  }

  static func wireless(_ server: FakeADBServer) -> ADBWireless {
    wireless(port: server.port)
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
    let services = try await Self.wireless(server).mdnsServices()
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
    let wireless = Self.wireless(server)
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
    #expect(try await Self.wireless(server).tcpPort(of: "S") == port)
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
    try await Self.wireless(server).restartInTCPMode(
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
      try await Self.wireless(server).restartInTCPMode(
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
    let info = try await Self.wireless(server).device(
      at: "192.0.2.31:5555")
    #expect(info?.id == DeviceID(serial: "fedcba9876543210"))
    #expect(info?.model == "EtherScope nXG")
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
