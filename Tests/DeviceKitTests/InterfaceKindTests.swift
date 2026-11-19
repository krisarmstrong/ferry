import DeviceKit
import Testing

/// Which kind of link each interface name a device reports is.
struct InterfaceKindTests {
  @Test(arguments: [
    ("wlan0", InterfaceKind.wifi), ("wlan1", .wifi), ("eth0", .ethernet), ("eth1", .ethernet),
    ("rmnet_data0", .mobileData), ("rmnet0", .mobileData), ("ccmni1", .mobileData),
    ("rndis0", .usb), ("usb0", .usb), ("eno0", .other("eno0")), ("dummy0", .other("dummy0")),
    ("tun0", .other("tun0")),
  ])
  func eachInterfaceHasItsKind(name: String, kind: InterfaceKind) {
    #expect(InterfaceKind(interface: name) == kind)
  }
}
