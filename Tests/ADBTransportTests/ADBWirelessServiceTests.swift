import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// What the server's connect, pair and disconnect services say, as AOSP's adb server writes it
/// (packages/modules/adb at 1cf2f017d312f73b3dc53bda85ef2610e35a80e9). The smart socket answers
/// `OKAY` as soon as it has started a host service (sockets.cpp:894); the service then writes its
/// own reply on the same connection.
enum ServiceReply: Sendable {
  /// `connect_service` and a successful `pair_service`: `SendProtocolString` (services.cpp:146,
  /// 153), a length-prefixed string after the smart socket's `OKAY`.
  case text(String)
  /// A failed `pair_service`: `SendFail` (services.cpp:155) after the `OKAY`, so `OKAY` `FAIL`
  /// then the length-prefixed reason.
  case failAfterOkay(String)
  /// `handle_host_request` for `disconnect:` (adb.cpp:1441): a plain `OKAY` or `FAIL` reply.
  case plain(String)
  case plainFail(String)
}

/// Connecting, pairing and disconnecting ask the server over the host protocol and never run an
/// adb, whose client of another version could restart a server another tool started.
struct ADBWirelessServiceTests {
  /// The requests `adb connect`, `adb pair` and `adb disconnect` send (client/commandline.cpp
  /// :1787, :1811, :1792), and the order `pair` takes: code first, then the address, split at
  /// the first `:` (services.cpp:271).
  @Test func requestsAreTheOnesTheAdbClientSends() {
    #expect(
      ADBWireless.connectRequest(ADBWirelessTests.etherScope) == "host:connect:192.0.2.31:5555")
    #expect(
      ADBWireless.disconnectRequest(ADBWirelessTests.etherScope)
        == "host:disconnect:192.0.2.31:5555")
    let pairing = WirelessEndpoint(parsing: "[fe80::1]:37123")!
    #expect(
      ADBWireless.pairRequest(pairing, ADBWirelessTests.code) == "host:pair:482913:[fe80::1]:37123")
  }

  @Test func aListedDeviceIsConnected() async throws {
    let requests = Box<[String]>([])
    let server = try await ADBWirelessTests.server(
      listing: "192.0.2.31:5555 device product:etherscope_nxg model:EtherScope_nXG\n",
      services: ["host:connect:192.0.2.31:5555": .text("connected to 192.0.2.31:5555")],
      requests: requests)
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).connect(ADBWirelessTests.etherScope)
    #expect(outcome == .connected(serial: "192.0.2.31:5555"))
    #expect(await requests.value.contains("host:connect:192.0.2.31:5555"))
  }

  /// The spike: the first connect says `failed to authenticate` (transport_emulator.cpp:126)
  /// and adb lists the address as unauthorised until the user taps Allow on the unit.
  @Test(arguments: [
    ("192.0.2.31:5555 unauthorized\n", "failed to authenticate to 192.0.2.31:5555"),
    ("", "failed to authenticate to 192.0.2.31:5555"),
    ("192.0.2.31:5555 unauthorized\n", "connected to 192.0.2.31:5555"),
  ])
  func unauthorisedWaitsForAllow(listing: String, reply: String) async throws {
    let server = try await ADBWirelessTests.server(
      listing: listing, services: ["host:connect:192.0.2.31:5555": .text(reply)])
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).connect(ADBWirelessTests.etherScope)
    #expect(outcome == .awaitingAllow)
  }

  /// The server answers `OKAY` and its words even when it could not connect: the list decides,
  /// its words are the detail.
  @Test func aRefusedConnectFailsWithTheServersWords() async throws {
    let server = try await ADBWirelessTests.server(
      listing: "",
      services: [
        "host:connect:192.0.2.31:5555": .text(
          "failed to connect to '192.0.2.31:5555': Connection refused")
      ])
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).connect(ADBWirelessTests.etherScope)
    #expect(outcome == .failed("failed to connect to '192.0.2.31:5555': Connection refused"))
  }

  /// No server: Ferry starts none for a connect, a pair or a disconnect, and runs no adb. A
  /// disconnect that reached no server did not disconnect anything, so it throws too.
  @Test func noServerIsUnavailable() async throws {
    let closed = try ClosedPort()
    let wireless = ADBWirelessTests.wireless(port: closed.port)
    await #expect(throws: ADBError.serverUnavailable) {
      _ = try await wireless.connect(ADBWirelessTests.etherScope)
    }
    await #expect(throws: ADBError.serverUnavailable) {
      _ = try await wireless.pair(ADBWirelessTests.etherScope, code: ADBWirelessTests.code)
    }
    await #expect(throws: ADBError.serverUnavailable) {
      try await wireless.disconnect(ADBWirelessTests.etherScope)
    }
  }

  @Test func pairingReportsTheGuidTheServerSends() async throws {
    let endpoint = WirelessEndpoint(parsing: "192.0.2.170:37123")!
    let server = try await ADBWirelessTests.server(
      listing: "",
      services: [
        "host:pair:482913:192.0.2.170:37123": .text(
          "Successfully paired to 192.0.2.170:37123 [guid=adb-fedcba9876543210-AbCdEf]")
      ])
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).pair(
      endpoint, code: ADBWirelessTests.code)
    #expect(outcome == .paired(guid: "adb-fedcba9876543210-AbCdEf"))
  }

  /// A current server fails a pair with `OKAY` then `FAIL` (services.cpp:155); an older one sent
  /// its `Failed: …` words as a reply. Both are a failure with the server's words.
  @Test(arguments: [
    ServiceReply.failAfterOkay("Failed: Wrong password or connection was dropped."),
    ServiceReply.text("Failed: Wrong password or connection was dropped."),
  ])
  func aWrongCodeFails(reply: ServiceReply) async throws {
    let server = try await ADBWirelessTests.server(
      listing: "", services: ["host:pair:482913:192.0.2.31:5555": reply])
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).pair(
      ADBWirelessTests.etherScope, code: ADBWirelessTests.code)
    #expect(outcome == .failed("Failed: Wrong password or connection was dropped."))
  }

  /// The server's own test is `StartsWith("Successful")` (services.cpp:151): a reply that only
  /// mentions success (adb_wifi.cpp:243) is a failure.
  @Test func aReplyThatOnlyMentionsSuccessFails() async throws {
    let words = "Failed: Successfully paired but server returned unknown response=x"
    let server = try await ADBWirelessTests.server(
      listing: "", services: ["host:pair:482913:192.0.2.31:5555": .text(words)])
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).pair(
      ADBWirelessTests.etherScope, code: ADBWirelessTests.code)
    #expect(outcome == .failed(words))
  }

  /// A server too old to pair says so in its own words, which echo the request: the code in
  /// them is hidden before they reach the menu.
  @Test func aServerWithoutPairingFailsWithoutTheCode() async throws {
    let server = try await ADBWirelessTests.server(listing: "")
    defer { server.stop() }
    let outcome = try await ADBWirelessTests.wireless(server).pair(
      ADBWirelessTests.etherScope, code: ADBWirelessTests.code)
    #expect(outcome == .failed("unknown host service 'host:pair:••••••:192.0.2.31:5555'"))
  }

  @Test func disconnectAsksTheServer() async throws {
    let requests = Box<[String]>([])
    let server = try await ADBWirelessTests.server(
      listing: "",
      services: ["host:disconnect:192.0.2.31:5555": .plain("disconnected 192.0.2.31:5555")],
      requests: requests)
    defer { server.stop() }
    try await ADBWirelessTests.wireless(server).disconnect(ADBWirelessTests.etherScope)
    #expect(await requests.value.contains("host:disconnect:192.0.2.31:5555"))
  }

  /// An address adb no longer has is already disconnected (adb.cpp:1470).
  @Test func disconnectingAnAddressAdbDoesNotHaveIsDone() async throws {
    let server = try await ADBWirelessTests.server(
      listing: "",
      services: [
        "host:disconnect:192.0.2.31:5555": .plainFail("no such device '192.0.2.31:5555'")
      ])
    defer { server.stop() }
    try await ADBWirelessTests.wireless(server).disconnect(ADBWirelessTests.etherScope)
  }

  /// Any other refusal is a disconnect that did not happen.
  @Test func anotherRefusalIsADisconnectThatFailed() async throws {
    let server = try await ADBWirelessTests.server(
      listing: "", services: ["host:disconnect:192.0.2.31:5555": .plainFail("busy")])
    defer { server.stop() }
    await #expect(throws: ADBError.failed("busy")) {
      try await ADBWirelessTests.wireless(server).disconnect(ADBWirelessTests.etherScope)
    }
  }
}
