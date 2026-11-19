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

  private func read(_ device: FakeAndroid) async throws -> AndroidDeviceInfo {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    let tools = ADBDeviceTools(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), answerLimit: .seconds(5),
      captureLimit: 1024, captureWait: .seconds(5))
    return try await tools.deviceInfo(serial: Self.serial)
  }

  private func device() -> FakeAndroid {
    let device = FakeAndroid()
    device.state.withLock {
      $0.properties = [
        "ro.product.model": "LinkRunner G2", "ro.build.version.release": "8.1.0",
        "ro.build.display.id": "OPM1.171019.026", "ro.serialno": Self.serial,
      ]
      $0.addresses = ADBWirelessTests.etherScopeAddresses
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
    #expect(info.addresses == ["192.0.2.31", "198.51.100.169", "192.0.2.166", "192.168.7.2"])
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
