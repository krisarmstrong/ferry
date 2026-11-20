import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Device info: the battery from `dumpsys battery`, the rest from `getprop`, `ip` and `df`, all
/// read-only.
@Suite(.timeLimit(.minutes(1)))
struct ADBDeviceInfoTests {
  static let serial = "0123456789abcdef"

  /// `dumpsys battery` as Android 8 prints it.
  static let battery = """
    Current Battery Service state:
      AC powered: false
      USB powered: true
      Wireless powered: false
      Max charging current: 500000
      Charge counter: 2200000
      status: 2
      health: 2
      present: true
      level: 87
      scale: 100
      voltage: 4123
      temperature: 281
      technology: Li-ion
    """

  @Test func theBatteryIsReadByItsLevelAndStatus() {
    #expect(
      ADBDeviceInfo.battery(fromDumpsys: Self.battery)
        == AndroidDeviceInfo.Battery(level: 87, state: .charging))
  }

  @Test(arguments: [
    (1, AndroidDeviceInfo.BatteryState.unknown), (2, .charging), (3, .discharging),
    (4, .notCharging), (5, .full), (9, .unknown),
  ])
  func eachStatusCodeHasAState(code: Int, state: AndroidDeviceInfo.BatteryState) {
    let text = "  status: \(code)\n  level: 50\n  scale: 100\n"
    #expect(ADBDeviceInfo.battery(fromDumpsys: text)?.state == state)
  }

  /// A level on another scale is shown as a percent; one beyond it is clamped.
  @Test func theLevelIsAPercent() {
    #expect(ADBDeviceInfo.battery(fromDumpsys: "status: 3\nlevel: 15\nscale: 30\n")?.level == 50)
    #expect(ADBDeviceInfo.battery(fromDumpsys: "status: 3\nlevel: 250\nscale: 100\n")?.level == 100)
  }

  /// The device prints these numbers; none of them can overflow the arithmetic.
  @Test func extremeNumbersAreBounded() {
    let max = Int.max
    #expect(ADBDeviceInfo.battery(fromDumpsys: "status: 3\nlevel: \(max)\n")?.level == 100)
    #expect(
      ADBDeviceInfo.battery(fromDumpsys: "status: 3\nlevel: \(max)\nscale: \(max)\n")?.level == 100)
    #expect(
      ADBDeviceInfo.battery(fromDumpsys: "status: 3\nlevel: \(max / 2)\nscale: \(max)\n")?.level
        == 49)
  }

  @Test func noBatteryIsNoBatteryNotAZero() {
    #expect(ADBDeviceInfo.battery(fromDumpsys: "") == nil)
    #expect(ADBDeviceInfo.battery(fromDumpsys: "Can't find service: battery") == nil)
    #expect(ADBDeviceInfo.battery(fromDumpsys: "status: 2\n") == nil)
    #expect(ADBDeviceInfo.battery(fromDumpsys: "level: abc\nstatus: 2\n") == nil)
  }

  /// `ip -o addr` as iproute2 prints it: one line per address, its continuation after `\`.
  static let oneLineAddresses = #"""
    1: lo    inet 127.0.0.1/8 scope host lo\    valid_lft forever preferred_lft forever
    1: lo    inet6 ::1/128 scope host \    valid_lft forever preferred_lft forever
    2: dummy0    inet 10.11.12.13/30 brd 10.11.12.15 scope global dummy0\    valid_lft forever preferred_lft forever
    3: eth0    inet 192.0.2.31/24 brd 192.0.2.255 scope global eth0\    valid_lft forever preferred_lft forever
    5: wlan0    inet 192.0.2.170/24 brd 192.0.2.255 scope global wlan0\    valid_lft forever preferred_lft forever
    5: wlan0    inet6 fe80::21a:2bff:fe3c:4d5e/64 scope link \    valid_lft forever preferred_lft forever
    5: wlan0    inet6 2001:db8::5/64 scope global dynamic \    valid_lft 86000sec preferred_lft 14000sec
    8: rmnet_data0    inet 100.64.1.2/30 scope global rmnet_data0\    valid_lft forever preferred_lft forever
    9: ccmni1    inet 100.64.9.9/30 scope global ccmni1\    valid_lft forever preferred_lft forever
    10: rndis0    inet 192.168.42.129/24 scope global rndis0\    valid_lft forever preferred_lft forever
    11: usb0    inet 192.168.43.1/24 scope global usb0\    valid_lft forever preferred_lft forever
    12: eth1@if11    inet 192.168.7.2/24 scope global eth1\    valid_lft forever preferred_lft forever
    13: tun0    inet 10.8.0.2/24 scope global tun0\    valid_lft forever preferred_lft forever
    """#

  /// Loopback and link-local IPv6 are left out; every other address keeps its interface.
  static let expectedAddresses: [AndroidDeviceInfo.Address] = [
    .init(interface: "dummy0", address: "10.11.12.13"),
    .init(interface: "eth0", address: "192.0.2.31"),
    .init(interface: "wlan0", address: "192.0.2.170"),
    .init(interface: "wlan0", address: "2001:db8::5"),
    .init(interface: "rmnet_data0", address: "100.64.1.2"),
    .init(interface: "ccmni1", address: "100.64.9.9"),
    .init(interface: "rndis0", address: "192.168.42.129"),
    .init(interface: "usb0", address: "192.168.43.1"),
    .init(interface: "eth1", address: "192.168.7.2"),
    .init(interface: "tun0", address: "10.8.0.2"),
  ]

  @Test func eachAddressKeepsItsInterface() {
    #expect(ADBDeviceInfo.addresses(fromOneLine: Self.oneLineAddresses) == Self.expectedAddresses)
  }

  /// Lines the device garbled, or with no address, are skipped; the rest still count.
  @Test func malformedLinesAreSkipped() {
    let text = """
      garbage
      4: eth0
      4: eth0    inet notanaddress/24 scope global eth0
      4: eth0    inet6
      : wlan0    inet 192.0.2.1/24 scope global wlan0
      6: wlan0    inet 192.0.2.9/24 scope global wlan0
      """
    #expect(
      ADBDeviceInfo.addresses(fromOneLine: text) == [
        .init(interface: "wlan0", address: "192.0.2.9")
      ])
  }

  /// An address with a NUL and more after it, or in another script's digits, is not one, though
  /// inet_pton reads only up to the NUL.
  @Test func anAddressWithMoreAfterItIsSkipped() {
    let text = """
      6: wlan0    inet 192.0.2.1\0tail/24 scope global wlan0
      6: wlan0    inet ١٩٢.0.2.2/24 scope global wlan0
      6: wlan0    inet6 2001:db8::1\0tail/64 scope global
      6: wlan0    inet 192.0.2.9/24 scope global wlan0
      """
    #expect(
      ADBDeviceInfo.addresses(fromOneLine: text) == [
        .init(interface: "wlan0", address: "192.0.2.9")
      ])
  }

  private func read(_ device: FakeAndroid) async throws -> AndroidDeviceInfo {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    let tools = ADBDeviceTools(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), answerLimit: .seconds(5),
      captureLimit: 1024, captureWait: .seconds(5))
    return try await tools.deviceInfo(route: ADBRoute(serial: Self.serial))
  }

  private func device() -> FakeAndroid {
    let device = FakeAndroid()
    device.state.withLock {
      $0.properties = [
        "ro.product.model": "LinkRunner G2", "ro.build.version.release": "8.1.0",
        "ro.build.display.id": "OPM1.171019.026", "ro.serialno": Self.serial,
      ]
      $0.oneLineAddresses = Self.oneLineAddresses
      $0.tools.battery = Self.battery
    }
    return device
  }

  @Test func theInfoIsGatheredFromTheDevice() async throws {
    let device = device()
    let info = try await read(device)
    #expect(info.model == "LinkRunner G2")
    #expect(info.androidVersion == "8.1.0")
    #expect(info.build == "OPM1.171019.026")
    #expect(info.serial == Self.serial)
    #expect(info.battery == .init(level: 87, state: .charging))
    #expect(info.addresses == Self.expectedAddresses)
    // The fake's internal storage: 23,260,324 KB, 272,504 KB used.
    let used: UInt64 = 272_504 * 1024
    let free: UInt64 = (23_260_324 - 272_504) * 1024
    #expect(info.storage == AndroidDeviceInfo.Storage(used: used, free: free))
  }

  /// Read-only: nothing but reading commands ran, each with its arguments quoted by the one
  /// builder.
  @Test func onlyReadingCommandsRun() async throws {
    let device = device()
    _ = try await read(device)
    let programs = Set(device.commands.map { $0[0] })
    #expect(programs == ["getprop", "dumpsys", "ip", "df"])
    #expect(device.commands.contains(["dumpsys", "battery"]))
    #expect(device.commands.contains(["df", "-k", "--", "/storage/emulated/0"]))
    #expect(device.commands.contains(["ip", "-o", "addr"]))
  }

  /// A device with no battery service or no `ip` still has the rest.
  @Test func whatTheDeviceCannotSayIsLeftOut() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.properties = ["ro.product.model": "Box"] }
    let info = try await read(device)
    #expect(info.model == "Box")
    #expect(info.androidVersion == "")
    #expect(info.battery == nil)
    #expect(info.addresses.isEmpty)
  }
}
