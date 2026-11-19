import Foundation
import Testing

@testable import DeviceKit

struct WirelessEndpointTests {
  static let accepted: [(String, String)] = [
    ("192.0.2.31", "192.0.2.31:5555"),
    ("192.0.2.31:5555", "192.0.2.31:5555"),
    ("192.0.2.31:37123", "192.0.2.31:37123"),
    ("etherscope", "etherscope:5555"),
    ("etherscope.lan:5555", "etherscope.lan:5555"),
    ("unit-7.example.com:1", "unit-7.example.com:1"),
    ("fe80::1", "[fe80::1]:5555"),
    ("[fe80::1]:6000", "[fe80::1]:6000"),
    ("[2001:db8::5]", "[2001:db8::5]:5555"),
    ("  192.0.2.31  ", "192.0.2.31:5555"),
    ("192.0.2.31:65535", "192.0.2.31:65535"),
  ]

  @Test(arguments: accepted)
  func parsesHostAndOptionalPort(text: String, argument: String) throws {
    let endpoint = try #require(WirelessEndpoint(parsing: text))
    #expect(endpoint.argument == argument)
  }

  /// Anything that could reach adb as an option, a second argument or a shell word is refused,
  /// as are ports out of range and hosts that are neither an IP literal nor a hostname.
  static let refused = [
    "", " ", "-s", "-H:5555", "--help", "192.0.2.31:0", "192.0.2.31:65536", "192.0.2.31:-1",
    "192.0.2.31:+55", "192.0.2.31:5555 extra", "192.0.2.31 -s", "a b", "host;rm", "$(x)",
    "host\n", "host\u{0}", "999.1.1.1", "192.0.2", "-unit.lan", "unit-.lan", "unit..lan",
    ".lan", "[fe80::1", "fe80::1]", "[10.0.0.1]:5555", "[fe80::1%en0]:5555", "192.0.2.31:",
    ":5555", "192.0.2.31:٥٥٥٥", "１０.0.0.1", "ünit.lan", "192.0.2.31:5555:1",
    String(repeating: "a", count: 64) + ".lan", String(repeating: "a.", count: 127) + "lan",
  ]

  @Test(arguments: refused)
  func refusesWhatIsNotAnAddress(text: String) {
    #expect(WirelessEndpoint(parsing: text) == nil)
  }

  @Test func pairingAsksForThePortTheDeviceShows() {
    #expect(WirelessEndpoint(parsing: "192.0.2.31", defaultPort: nil) == nil)
    #expect(
      WirelessEndpoint(parsing: "192.0.2.31:37123", defaultPort: nil)?.argument
        == "192.0.2.31:37123")
  }

  @Test func decodingValidatesAsParsingDoes() throws {
    let good = try JSONEncoder().encode(try #require(WirelessEndpoint(parsing: "unit.lan:5555")))
    #expect(try JSONDecoder().decode(WirelessEndpoint.self, from: good).argument == "unit.lan:5555")
    let bad = Data(#"{"host":"-s","port":5555}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(WirelessEndpoint.self, from: bad)
    }
    let badPort = Data(#"{"host":"unit.lan","port":0}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(WirelessEndpoint.self, from: badPort)
    }
  }
}

struct PairingCodeTests {
  @Test(arguments: ["123456", "000000", " 482913 "])
  func acceptsSixDigits(text: String) throws {
    let code = try #require(PairingCode(text))
    #expect(code.digits == text.trimmingCharacters(in: .whitespaces))
  }

  @Test(arguments: ["", "12345", "1234567", "12345a", "-12345", "١٢٣٤٥٦", "123 456", "12345\n"])
  func refusesAnythingElse(text: String) {
    #expect(PairingCode(text) == nil)
  }

  /// A code that reaches a log through `describing:` shows nothing of itself.
  @Test func neverDescribesItsDigits() throws {
    let code = try #require(PairingCode("482913"))
    #expect(!String(describing: code).contains("482913"))
    #expect(!String(reflecting: code).contains("482913"))
  }

  @Test func decodingValidates() throws {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(PairingCode.self, from: Data(#""12a456""#.utf8))
    }
    let code = try JSONDecoder().decode(PairingCode.self, from: Data(#""482913""#.utf8))
    #expect(code.digits == "482913")
  }

  /// A NUL ends the text inet_pton reads, not the text Ferry would pass on to adb.
  @Test(arguments: ["192.0.2.1\0", "192.0.2.1\0x", "١٩٢.0.2.1"])
  func anAddressWithMoreAfterItIsRefused(text: String) {
    #expect(WirelessEndpoint(parsing: text) == nil)
  }

  /// A typed IPv4 address with leading zeros is refused, with or without a port: adb may read a
  /// part such as `010` as octal (8), so it would reach a different host than the one typed.
  @Test(arguments: ["192.0.2.01", "010.0.2.1", "192.0.2.010:5555"])
  func anIPv4AddressWithLeadingZerosIsRefused(text: String) {
    #expect(WirelessEndpoint(parsing: text) == nil)
  }
}
