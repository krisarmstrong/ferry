import Foundation

/// Where to reach a device's adb over the network: an IPv4 or IPv6 literal, or a hostname, and a
/// port from 1 to 65535.
///
/// It is passed to `adb` as one argument, so it must never read as an option or carry anything
/// but an address: a hostname is ASCII letters, digits and hyphens in dot-separated labels, none
/// starting or ending with a hyphen, so no value starts with `-`. Decoding validates the same
/// way, so a value from a client or a file is checked before it is used.
public struct WirelessEndpoint: Hashable, Sendable, Codable {
  public static let defaultPort: UInt16 = 5555

  public let host: String
  public let port: UInt16

  public init?(host: String, port: UInt16) {
    guard port > 0, Self.isHost(host) else { return nil }
    self.host = host
    self.port = port
  }

  /// Reads `host`, `host:port`, `[v6]:port` or a bare IPv6 literal. Without a port it takes
  /// `defaultPort`, or fails when that is `nil` (pairing, whose port the device shows).
  public init?(parsing text: String, defaultPort: UInt16? = Self.defaultPort) {
    guard let (host, port) = Self.split(text.trimmingCharacters(in: .whitespaces)) else {
      return nil
    }
    // A port that is given must be valid; only a missing one falls back.
    let number = if let port { Self.port(port) } else { defaultPort }
    guard let number else { return nil }
    self.init(host: String(host), port: number)
  }

  /// The host and the port's digits, if any. A bracketed or bare host holding colons must be
  /// an IPv6 literal.
  private static func split(_ text: String) -> (Substring, Substring?)? {
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return nil }
      let host = text[text.index(after: text.startIndex)..<close]
      let rest = text[text.index(after: close)...]
      guard isIPv6(String(host)), rest.isEmpty || rest.hasPrefix(":") else { return nil }
      return (host, rest.isEmpty ? nil : rest.dropFirst())
    }
    if text.count(where: { $0 == ":" }) > 1 {
      return isIPv6(text) ? (Substring(text), nil) : nil
    }
    guard let colon = text.firstIndex(of: ":") else { return (Substring(text), nil) }
    return (text[..<colon], text[text.index(after: colon)...])
  }

  /// Whether the host is an IP address rather than a name.
  public var isAddressLiteral: Bool { Self.addressBytes(host) != nil }

  /// Whether `other` names the same host: the same address for IP literals (so `2001:db8::5`
  /// and `2001:DB8:0::5` match), the same name, ignoring ASCII case, for hostnames. Zones are
  /// refused at parsing, so a link-local IPv6 address never gets here: it would need its zone
  /// to be compared, and to be reached at all.
  public func isSameHost(as other: WirelessEndpoint) -> Bool {
    if let mine = Self.addressBytes(host), let theirs = Self.addressBytes(other.host) {
      return mine == theirs
    }
    return host.lowercased() == other.host.lowercased()
  }

  private static func addressBytes(_ host: String) -> [UInt8]? {
    if isIPv4(host) {
      var address = in_addr()
      inet_pton(AF_INET, host, &address)
      return withUnsafeBytes(of: &address) { Array($0) }
    }
    guard isIPv6(host) else { return nil }
    var address = in6_addr()
    inet_pton(AF_INET6, host, &address)
    return withUnsafeBytes(of: &address) { Array($0) }
  }

  /// The address as adb takes it: `host:port`, with an IPv6 literal in brackets.
  public var argument: String {
    Self.isIPv6(host) ? "[\(host)]:\(port)" : "\(host):\(port)"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let host = try container.decode(String.self, forKey: .host)
    let port = try container.decode(UInt16.self, forKey: .port)
    guard let endpoint = WirelessEndpoint(host: host, port: port) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid network address"))
    }
    self = endpoint
  }

  /// ASCII digits only (no sign, no other scripts' digits), 1 to 65535.
  private static func port(_ text: Substring) -> UInt16? {
    guard (1...5).contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      let value = UInt16(text), value > 0
    else { return nil }
    return value
  }

  private static func isHost(_ host: String) -> Bool {
    isIPv4(host) || isIPv6(host) || isHostname(host)
  }

  /// Dotted decimal, four parts, so `10.1` is not an address.
  private static func isIPv4(_ text: String) -> Bool {
    NumericAddress.isIPv4(text)
  }

  /// Without a zone (`%en0`), which inet_pton accepts but adb's serials do not carry.
  private static func isIPv6(_ text: String) -> Bool {
    var address = in6_addr()
    return text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
      && inet_pton(AF_INET6, text, &address) == 1
  }

  /// RFC 1123 labels. A name whose last label is all digits would be a mistyped IPv4 address,
  /// which `isIPv4` already refused.
  private static func isHostname(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty, bytes.count <= 253 else { return false }
    let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
    let hyphen = UInt8(ascii: "-")
    for label in labels {
      guard (1...63).contains(label.count), label.first != hyphen, label.last != hyphen,
        label.allSatisfy({ isLetterOrDigit($0) || $0 == hyphen })
      else { return false }
    }
    return !(labels.last ?? []).allSatisfy { (0x30...0x39).contains($0) }
  }

  private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
  }
}

/// The six-digit code Android 11+ shows for pairing over Wi-Fi. It never describes itself, so a
/// code that reaches a log shows nothing.
public struct PairingCode: Hashable, Sendable, Codable, CustomStringConvertible {
  public let digits: String

  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespaces)
    guard text.utf8.count == 6, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
      return nil
    }
    digits = text
  }

  public init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let code = PairingCode(text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid pairing code"))
    }
    self = code
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(digits)
  }

  /// `String(reflecting:)` uses this too.
  public var description: String { "PairingCode(••••••)" }
}
