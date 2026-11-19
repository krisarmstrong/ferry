import Testing

@testable import DeviceKit

/// A numeric address the device or the user wrote: accepted only as the plain ASCII text
/// `inet_ntop` would write for it, so nothing after a NUL or in another script's digits gets
/// through with it.
struct NumericAddressTests {
  @Test(arguments: ["192.0.2.1", "192.0.2.0", "192.0.2.255"])
  func anIPv4AddressIsAccepted(text: String) {
    #expect(NumericAddress.isIPv4(text))
  }

  @Test(arguments: [
    "192.0.2.1\0", "192.0.2.1\0tail", "192.0.2.1 ", " 192.0.2.1", "١٩٢.0.2.1", "１92.0.2.1",
    "192.0.2.01", "192.0.2", "192.0.2.256", "", "::ffff:192.0.2.1",
  ])
  func anythingElseIsNotIPv4(text: String) {
    #expect(!NumericAddress.isIPv4(text))
  }

  @Test(arguments: ["2001:db8::1", "::1", "2001:db8:0:1::abcd", "::ffff:192.0.2.1"])
  func anIPv6AddressIsAccepted(text: String) {
    #expect(NumericAddress.isIPv6(text))
  }

  @Test(arguments: [
    "2001:db8::1\0", "2001:db8::1\0tail", "2001:db8::1 ", "2001:db8::١", "2001:db8::%en0",
    "2001:DB8::1", "2001:0db8::1", "192.0.2.1", "",
  ])
  func anythingElseIsNotIPv6(text: String) {
    #expect(!NumericAddress.isIPv6(text))
  }
}
