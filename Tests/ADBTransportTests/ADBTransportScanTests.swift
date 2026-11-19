import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

struct ADBTransportScanTests {
  typealias Fixture = TransportFixture

  @Test func usbAndWiFiOfOneDeviceAreOneDeviceWithBothRoutes() async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([
      .init(Fixture.linkRunnerSerial, model: "LinkRunner_G2", device: android),
      .init(Fixture.linkRunnerWiFi, model: "LinkRunner_G2", device: android),
    ])
    let transport = Fixture.transport(port: hub.port)
    let scan = try await transport.scan()
    #expect(scan.devices == [Fixture.linkRunnerInfo])
    #expect(scan.notSharing.isEmpty && scan.busy.isEmpty && scan.ejected.isEmpty)
    #expect(
      await transport.routes(for: Fixture.linkRunner)
        == ADBRoutes(usb: Fixture.linkRunnerSerial, wireless: [Fixture.linkRunnerWiFi]))
    #expect(await transport.status == .available)

    // USB is preferred while it is there.
    let usb = try #require(try await transport.open(Fixture.linkRunner) as? ADBSession)
    #expect(await usb.serial == Fixture.linkRunnerSerial)
    await usb.close()

    // The cable is pulled: the same device, over Wi-Fi.
    hub.set([.init(Fixture.linkRunnerWiFi, device: android)])
    #expect(try await transport.scan().devices == [Fixture.linkRunnerInfo])
    #expect(
      await transport.routes(for: Fixture.linkRunner)
        == ADBRoutes(usb: nil, wireless: [Fixture.linkRunnerWiFi]))
    let wifi = try #require(try await transport.open(Fixture.linkRunner) as? ADBSession)
    #expect(await wifi.serial == Fixture.linkRunnerWiFi)
    #expect(try await wifi.storages().map(\.id.key) == ["internal"])
    await wifi.close()

    // Each adb serial was asked for its ro.serialno once, however many scans.
    _ = try await transport.scan()
    #expect(Fixture.lookups(of: "ro.serialno", on: android) == 2)
    await hub.kill()
  }

  /// adb reconnects a network address by itself, and DHCP may have given that address to
  /// another unit in between. adb numbers each connection anew, so a new number is a new
  /// device until its properties say otherwise.
  @Test func aReconnectedAddressIsNamedAgain() async throws {
    let first = Fixture.android(serial: "0123456789ABCDEF", model: "LinkRunner G2")
    let second = Fixture.android(serial: "FEDCBA9876543210", model: "LinkRunner G2")
    let address = "192.0.2.5:5555"
    let hub = try await Fixture.hub([.init(address, device: first, transportID: 1)])
    let transport = Fixture.transport(port: hub.port)
    #expect(try await transport.scan().devices.map(\.id) == [DeviceID(serial: "0123456789ABCDEF")])
    hub.set([.init(address, device: second, transportID: 2)])
    #expect(try await transport.scan().devices.map(\.id) == [DeviceID(serial: "FEDCBA9876543210")])
    // The same connection is not asked again.
    _ = try await transport.scan()
    #expect(Fixture.lookups(of: "ro.serialno", on: second) == 1)
    await hub.kill()
  }

  /// The scan says how each device is reached: USB while the cable is in, else the network.
  @Test func eachDeviceIsReportedWithItsRoute() async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let etherScope = Fixture.android(serial: "fedcba9876543210", model: "EtherScope nXG")
    let hub = try await Fixture.hub([
      .init(Fixture.linkRunnerSerial, device: android),
      .init(Fixture.linkRunnerWiFi, device: android),
      .init("192.0.2.40:5555", device: etherScope),
      .init("192.0.2.50:5555", "unauthorized", device: nil),
      .init("abc", "unauthorized", device: nil),
    ])
    let transport = Fixture.transport(port: hub.port)
    let scan = try await transport.scan()
    #expect(scan.method(of: Fixture.linkRunner) == .usbADB)
    #expect(scan.method(of: DeviceID(serial: "fedcba9876543210")) == .wifiADB)
    #expect(scan.awaitingAuthorization == ["192.0.2.50:5555"])
    #expect(scan.method(of: DeviceID(serial: "abc")) == .usbADB)
    await hub.kill()
  }

  /// A board on a reference design reports its SoC maker as its manufacturer, which says nothing
  /// about the device; it is left out rather than shown.
  @Test(arguments: [("freescale", ""), ("Android", ""), ("", ""), ("Google", "Google")])
  func aPlatformManufacturerIsLeftOut(_ reported: String, _ shown: String) async throws {
    let android = Fixture.android(
      serial: Fixture.linkRunnerSerial, manufacturer: reported, model: "LinkRunner-100G")
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerSerial, device: android)])
    let scan = try await Fixture.transport(port: hub.port).scan()
    #expect(
      scan.devices
        == [DeviceInfo(id: Fixture.linkRunner, manufacturer: shown, model: "LinkRunner-100G")])
    await hub.kill()
  }

  /// The unit is on the cable, unauthorised or offline, and a network device answers with its
  /// serial: the network does not serve it. The USB entry stands, and its serial is reported as
  /// present over USB.
  @Test(arguments: ["unauthorized", "offline"])
  func aUSBEntryInAnyStateBlocksTheNetwork(_ state: String) async throws {
    let android = Fixture.android(serial: Fixture.linkRunnerSerial)
    let hub = try await Fixture.hub([
      .init(Fixture.linkRunnerSerial, state, device: nil),
      .init(Fixture.linkRunnerWiFi, device: android),
    ])
    let scan = try await Fixture.transport(port: hub.port).scan()
    #expect(scan.devices.isEmpty)
    #expect(scan.presentOverUSB == [Fixture.linkRunner])
    #expect(scan.notSharing.map(\.id) == (state == "unauthorized" ? [Fixture.linkRunner] : []))
    await hub.kill()
  }

  @Test func unauthorizedIsNotSharingByItsAdbSerialAndOfflineIsLeftOut() async throws {
    let hub = try await Fixture.hub([
      .init("abc", "unauthorized", device: nil),
      .init("def", "offline", device: nil),
      .init("192.0.2.31:5555", "unauthorized", device: nil),
      .init("ghi", "recovery", device: nil),
    ])
    let transport = Fixture.transport(port: hub.port)
    let scan = try await transport.scan()
    #expect(scan.devices.isEmpty)
    #expect(scan.notSharing.map(\.id.serial) == ["abc"])
    #expect(scan.awaitingAuthorization == ["192.0.2.31:5555"])
    // Only an unauthorised USB entry waits for the user to allow USB debugging.
    #expect(scan.awaitingUSBDebugging == [DeviceID(serial: "abc")])
    #expect(scan.adbStatus == .available)
    await hub.kill()
  }

  @Test func anAnsweringServerIsAvailableAndWaitsForNobody() async throws {
    let hub = try await Fixture.hub([
      .init(Fixture.linkRunnerSerial, device: Fixture.android(serial: Fixture.linkRunnerSerial))
    ])
    let scan = try await Fixture.transport(port: hub.port).scan()
    #expect(scan.adbStatus == .available)
    #expect(scan.awaitingUSBDebugging.isEmpty)
    await hub.kill()
  }

  /// Check again with no `adb` to find is no error: the scan still says it is not installed.
  @Test func startingAdbThatIsNotInstalledChangesNothing() async throws {
    let closed = try ClosedPort()
    let transport = Fixture.transport(port: closed.port, locator: ADBHostTests.noAdb)
    await transport.startADBServer()
    #expect(try await transport.scan().adbStatus == .notInstalled)
    withExtendedLifetime(closed) {}
  }

  @Test func anAddressReusedByAnotherDeviceIsAskedAgain() async throws {
    let first = Fixture.android(serial: "fedcba9876543210", model: "EtherScope nXG")
    let second = Fixture.android(serial: "1122334455667788", model: "CyberScope")
    let hub = try await Fixture.hub([.init(Fixture.linkRunnerWiFi, device: first)])
    let transport = Fixture.transport(port: hub.port)
    #expect(try await transport.scan().devices.map(\.id.serial) == ["fedcba9876543210"])
    hub.set([])
    #expect(try await transport.scan().devices.isEmpty)
    hub.set([.init(Fixture.linkRunnerWiFi, device: second)])
    #expect(try await transport.scan().devices.map(\.id.serial) == ["1122334455667788"])
    await hub.kill()
  }

  @Test func aDeviceWithoutASerialIsLeftOutAndAskedAgainNextScan() async throws {
    let android = Fixture.android(serial: "")
    let hub = try await Fixture.hub([.init("emulator-5554", device: android)])
    let transport = Fixture.transport(port: hub.port)
    #expect(try await transport.scan().devices.isEmpty)
    android.state.withLock { $0.properties["ro.serialno"] = "EMULATOR35X1" }
    #expect(try await transport.scan().devices.map(\.id.serial) == ["EMULATOR35X1"])
    await hub.kill()
  }

  @Test func adbNotInstalledIsAnEmptyScanAndNotInstalled() async throws {
    let closed = try ClosedPort()
    let transport = Fixture.transport(port: closed.port, locator: ADBHostTests.noAdb)
    let scan = try await transport.scan()
    #expect(scan == DeviceScan(devices: [], method: .usbADB, adbStatus: .notInstalled))
    #expect(await transport.status == .notInstalled)
    withExtendedLifetime(closed) {}
  }

  @Test func installedWithNoServerIsServerDown() async throws {
    let closed = try ClosedPort()
    let transport = Fixture.transport(port: closed.port)
    #expect(
      try await transport.scan() == DeviceScan(devices: [], method: .usbADB, adbStatus: .serverDown)
    )
    #expect(await transport.status == .serverDown)
    withExtendedLifetime(closed) {}
  }
}
