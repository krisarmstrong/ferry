import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

struct WirelessADBTests {
  static let etherScope = DeviceInfo(
    id: DeviceID(serial: "fedcba9876543210"), manufacturer: "", model: "EtherScope nXG")
  static let linkRunner = DeviceInfo(
    id: DeviceID(serial: "0123456789abcdef"), manufacturer: "", model: "LinkRunner-100G")
  static let fast = WirelessADB.Timing(
    mdnsInterval: .milliseconds(20), settle: .milliseconds(200), poll: .milliseconds(10))

  static func endpoint(_ text: String) -> WirelessEndpoint { WirelessEndpoint(parsing: text)! }

  static func storeFile() -> URL {
    TestScratch.root.appending(path: "ferry-wireless-\(UUID()).json")
  }

  // MARK: Connect by address

  @Test(.timeLimit(.minutes(1)))
  func connectByAddressRemembersTheUnitBySerial() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope) }
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(await wireless.connect(Self.endpoint("192.0.2.31")) == .connected)
    #expect(await adb.calls == [.connect("192.0.2.31:5555")])
    #expect(
      await wireless.remembered() == [
        RememberedDevice(
          id: Self.etherScope.id, name: "EtherScope nXG",
          addresses: [Self.endpoint("192.0.2.31:5555")])
      ])
    // Saved: a new agent reads it back.
    let reloaded = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(await reloaded.remembered().map(\.id) == [Self.etherScope.id])
  }

  /// Not yet allowed: the serial is unknown, so the address waits, and is remembered once adb
  /// lists it as allowed.
  @Test(.timeLimit(.minutes(1)))
  func anAddressWaitingForAllowIsRememberedOnceAllowed() async throws {
    let adb = FakeWirelessADB()
    await adb.set {
      $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope, authorized: false)
    }
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(
      await wireless.connect(Self.endpoint("192.0.2.31"))
        == .awaitingAllow(Self.endpoint("192.0.2.31:5555")))
    #expect(await wireless.remembered().isEmpty)
    await adb.set {
      $0.units["192.0.2.31:5555"]?.authorized = true
      $0.listed["192.0.2.31:5555"] = .device
    }
    await adb.publish()
    #expect(
      try await eventually { await wireless.remembered().map(\.id) == [Self.etherScope.id] })
  }

  @Test(.timeLimit(.minutes(1)))
  func aRefusedAddressIsNotRemembered() async throws {
    let adb = FakeWirelessADB()
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(
      await wireless.connect(Self.endpoint("192.0.2.99"))
        == .failed(.adb("failed to connect to '192.0.2.99:5555': Connection refused")))
    #expect(await wireless.remembered().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func noServerIsAdbUnavailable() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.serverUp = false }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(await wireless.connect(Self.endpoint("192.0.2.31")) == .failed(.adbUnavailable))
  }

  // MARK: Pairing (Android 11+)

  /// Connects to the `_adb-tls-connect` service of the instance adb paired with, and to no other.
  @Test(.timeLimit(.minutes(1)))
  func pairingConnectsToThePairedInstancesConnectService() async throws {
    let adb = FakeWirelessADB()
    let guid = "adb-PX8SERIAL-AbCdEf"
    let pixel = DeviceInfo(
      id: DeviceID(serial: "PX8SERIAL"), manufacturer: "Google", model: "Pixel 8")
    await adb.set {
      $0.pairOutcome = .paired(guid: guid)
      $0.mdns = [
        ADBMDNSService(
          name: "adb-OTHER-Zz", type: "_adb-tls-connect._tcp",
          endpoint: Self.endpoint("192.0.2.50:40000")),
        ADBMDNSService(
          name: guid, type: "_adb-tls-pairing._tcp", endpoint: Self.endpoint("192.0.2.169:37123")),
        ADBMDNSService(
          name: guid, type: "_adb-tls-connect._tcp", endpoint: Self.endpoint("192.0.2.169:41235")),
      ]
      $0.units["192.0.2.169:41235"] = .init(info: pixel)
      $0.units["192.0.2.50:40000"] = .init(info: Self.etherScope)
    }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    let outcome = await wireless.pair(
      Self.endpoint("192.0.2.169:37123"), code: PairingCode("482913")!)
    #expect(outcome == .connected)
    let calls = await adb.calls
    #expect(calls.first == .pair("192.0.2.169:37123"))
    #expect(calls.contains(.connect("192.0.2.169:41235")))
    #expect(!calls.contains(.connect("192.0.2.50:40000")))
    #expect(await wireless.remembered().map(\.id) == [pixel.id])
  }

  @Test(.timeLimit(.minutes(1)))
  func aPairedDeviceWithNoConnectServiceSaysSo() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.pairOutcome = .paired(guid: "adb-X-1") }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(
      await wireless.pair(Self.endpoint("192.0.2.169:37123"), code: PairingCode("482913")!)
        == .failed(.noConnectService))
  }

  @Test(.timeLimit(.minutes(1)))
  func aWrongCodeFailsWithAdbsWords() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.pairOutcome = .failed("Failed: Wrong password or connection was dropped.") }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(
      await wireless.pair(Self.endpoint("192.0.2.169:37123"), code: PairingCode("000000")!)
        == .failed(.adb("Failed: Wrong password or connection was dropped.")))
    #expect(await adb.calls == [.pair("192.0.2.169:37123")])
  }

  // MARK: Use over Wi-Fi (Android 8–10, from USB)

  /// The EtherScope already listens on 5555: its addresses are used directly, no `tcpip`.
  @Test(.timeLimit(.minutes(1)))
  func aUnitAlreadyListeningIsConnectedWithoutTcpip() async throws {
    let adb = FakeWirelessADB()
    let serial = Self.etherScope.id.serial
    await adb.set {
      $0.listed[serial] = .device
      $0.usb[serial] = .init(info: Self.etherScope)
      $0.tcpPorts[serial] = 5555
      $0.addresses[serial] = ["192.0.2.31", "192.0.2.169"]
      $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope)
    }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(await wireless.useOverWiFi(Self.etherScope.id) == .connected)
    let calls = await adb.calls
    #expect(!calls.contains { if case .tcpip = $0 { true } else { false } })
    #expect(calls == [.connect("192.0.2.31:5555")])
    #expect(
      await wireless.remembered().first?.addresses == [
        Self.endpoint("192.0.2.31:5555"), Self.endpoint("192.0.2.169:5555"),
      ])
  }

  @Test(.timeLimit(.minutes(1)))
  func aUnitNotListeningIsSwitchedWithTcpipFirst() async throws {
    let adb = FakeWirelessADB()
    let serial = Self.linkRunner.id.serial
    await adb.set {
      $0.listed[serial] = .device
      $0.usb[serial] = .init(info: Self.linkRunner)
      $0.addresses[serial] = ["192.0.2.40"]
      $0.units["192.0.2.40:5555"] = .init(info: Self.linkRunner)
    }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(await wireless.useOverWiFi(Self.linkRunner.id) == .connected)
    #expect(await adb.calls == [.tcpip(serial, 5555), .connect("192.0.2.40:5555")])
  }

  /// The LinkRunner in the spike: only `dummy0` had an address. Nothing is restarted.
  @Test(.timeLimit(.minutes(1)))
  func aUnitWithNoNetworkNeedsOneFirst() async throws {
    let adb = FakeWirelessADB()
    let serial = Self.linkRunner.id.serial
    await adb.set {
      $0.listed[serial] = .device
      $0.usb[serial] = .init(info: Self.linkRunner)
    }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(await wireless.useOverWiFi(Self.linkRunner.id) == .needsNetwork)
    #expect(await adb.calls.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDeviceNotOnUSBADBCannotBeSwitched() async throws {
    let adb = FakeWirelessADB()
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(await wireless.useOverWiFi(Self.linkRunner.id) == .failed(.notOverUSB))
  }

  /// An address the unit reports that answers as another unit is dropped, never remembered.
  @Test(.timeLimit(.minutes(1)))
  func anAddressAnsweringAsAnotherUnitIsDisconnected() async throws {
    let adb = FakeWirelessADB()
    let serial = Self.linkRunner.id.serial
    await adb.set {
      $0.listed[serial] = .device
      $0.usb[serial] = .init(info: Self.linkRunner)
      $0.tcpPorts[serial] = 5555
      $0.addresses[serial] = ["192.0.2.31"]
      $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope)
    }
    let wireless = WirelessADB(adb: adb, store: Self.storeFile(), timing: Self.fast)
    #expect(await wireless.useOverWiFi(Self.linkRunner.id) == .failed(.otherDevice))
    #expect(await adb.calls == [.connect("192.0.2.31:5555"), .disconnect("192.0.2.31:5555")])
    #expect(await wireless.remembered().isEmpty)
  }
}
