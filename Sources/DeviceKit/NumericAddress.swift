import Foundation

/// Whether text a device or the user wrote is a numeric IP address. `inet_pton` reads a C string,
/// so it stops at the first NUL and would pass `192.0.2.1\0<anything>`: the text must be ASCII
/// address characters only, and exactly what `inet_ntop` writes back for the address.
public enum NumericAddress {
  /// Dotted decimal, four parts, no leading zeros.
  public static func isIPv4(_ text: String) -> Bool {
    let allowed = text.utf8.allSatisfy { (0x30...0x39).contains($0) || $0 == UInt8(ascii: ".") }
    var address = in_addr()
    return allowed && roundTrips(text, family: AF_INET, into: &address)
  }

  /// In the form `inet_ntop` writes: lowercase hex, zeros compressed, no zone.
  public static func isIPv6(_ text: String) -> Bool {
    let allowed = text.utf8.allSatisfy {
      (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || $0 == UInt8(ascii: ":")
        || $0 == UInt8(ascii: ".")
    }
    var address = in6_addr()
    return allowed && roundTrips(text, family: AF_INET6, into: &address)
  }

  private static func roundTrips<Address>(
    _ text: String, family: Int32, into address: inout Address
  ) -> Bool {
    guard inet_pton(family, text, &address) == 1 else { return false }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(family, &address, &buffer, socklen_t(buffer.count)) != nil else {
      return false
    }
    let written = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
    return String(bytes: written, encoding: .ascii) == text
  }
}
