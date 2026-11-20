import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// Fix round 2: forgets win over queued reconnects, one waiting hold per address, serving is
/// closed until the store is loaded, pairing trusts only the pairing host, failed connects are
/// disconnected, consent text comes from Ferry, and the store is private.
struct WirelessADBFixRound2Tests {
  static let etherScope = WirelessADBTests.etherScope
  static let fast = WirelessADBTests.fast
  static let code = PairingCode("482913")!

  static func endpoint(_ text: String) -> WirelessEndpoint { WirelessADBTests.endpoint(text) }

  /// Five remembered devices behind connects that hang; the one queued behind the first four is
  /// forgotten meanwhile. It is never tried, remembered or served again.
  @Test(.timeLimit(.minutes(1)))
  func aDeviceForgottenWhileItsReconnectIsQueuedStaysForgotten() async throws {
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let devices = (1...5).map { index in
      #""U\#(index)":{"name":"Unit","addresses":[{"address":"203.0.113.\#(index):5555","learnt":"usb"}]}"#
    }
    try Data(#"{"devices":{\#(devices.joined(separator: ","))}}"#.utf8).write(to: file)
    let adb = FakeWirelessADB()
    await adb.set {
      for index in 1...5 {
        let address = "203.0.113.\(index):5555"
        $0.connectDelay[address] = .milliseconds(500)
        $0.units[address] = .init(
          info: DeviceInfo(id: DeviceID(serial: "U\(index)"), manufacturer: "", model: "Unit"))
      }
    }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(try await eventually { await adb.inFlight == 4 })
    // Whichever one is still queued: the order of the remembered list is not fixed.
    let tried = await adb.calls
    let queued = try #require(
      (1...5).first { !tried.contains(.connect("203.0.113.\($0):5555")) })
    let fifth = DeviceID(serial: "U\(queued)")
    await wireless.forget(fifth)
    #expect(
      try await eventually {
        let connects = await adb.calls.filter { if case .connect = $0 { true } else { false } }
        let busy = await adb.inFlight
        return connects.count >= 4 && busy == 0
      })
    try await Task.sleep(for: .milliseconds(700))
    #expect(!(await adb.calls.contains(.connect("203.0.113.\(queued):5555"))))
    #expect(await adb.calls.contains(.disconnect("203.0.113.\(queued):5555")))
    #expect(await !wireless.remembered().map(\.id).contains(fifth))
  }

  /// A reconnect already inside `adb connect` when the device is forgotten does not bring it
  /// back.
  @Test(.timeLimit(.minutes(1)))
  func aDeviceForgottenDuringItsReconnectIsNotRemembered() async throws {
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let stored = """
      {"devices":{"fedcba9876543210":{"name":"EtherScope nXG","addresses":[\
      {"address":"192.0.2.31:5555","learnt":"usb"}]}}}
      """
    try Data(stored.utf8).write(to: file)
    let adb = FakeWirelessADB()
    await adb.set {
      $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope)
      $0.connectDelay["192.0.2.31:5555"] = .milliseconds(300)
    }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(try await eventually { await adb.inFlight == 1 })
    await wireless.forget(Self.etherScope.id)
    try await Task.sleep(for: .milliseconds(500))
    #expect(await wireless.remembered().isEmpty)
    #expect(await adb.calls.last == .disconnect("192.0.2.31:5555"))
  }

  /// Two Connects while the device waits for Allow hold the address once: allowed, it is served.
  @Test(.timeLimit(.minutes(1)))
  func connectingTwiceWhileWaitingStillServesOnceAllowed() async throws {
    let adb = FakeWirelessADB()
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    let address = Self.endpoint("192.0.2.50")
    let unit = DeviceInfo(id: DeviceID(serial: "NEWUNIT1"), manufacturer: "", model: "New")
    await adb.set { $0.units[address.argument] = .init(info: unit, authorized: false) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast, vouching: vouching)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(await wireless.connect(address) == .awaitingAllow(address))
    #expect(await wireless.connect(address) == .awaitingAllow(address))
    await adb.set {
      $0.units[address.argument]?.authorized = true
      $0.listed[address.argument] = .device
    }
    await adb.publish()
    #expect(try await eventually { await wireless.remembered().map(\.id) == [unit.id] })
    #expect(try await eventually { vouching.serves(address.argument, as: unit.id) })
  }

  /// The adb server outlives the agent: until the store is loaded no network route is served,
  /// not even one for a device Ferry has never seen.
  @Test(.timeLimit(.minutes(1)))
  func servingIsClosedUntilTheStoreIsLoaded() async throws {
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    #expect(!vouching.serves("192.0.2.50:5555", as: DeviceID(serial: "NEWUNIT1")))
    #expect(!vouching.serves("192.0.2.31:5555", as: Self.etherScope.id))
    let ticks = Mutex(0)
    let follower = Task { for await _ in vouching.changes { ticks.withLock { $0 += 1 } } }
    defer { follower.cancel() }
    _ = WirelessADB(
      adb: FakeWirelessADB(), store: WirelessADBTests.storeFile(), timing: Self.fast,
      vouching: vouching)
    #expect(vouching.serves("192.0.2.50:5555", as: DeviceID(serial: "NEWUNIT1")))
    #expect(try await eventually { ticks.withLock { $0 } > 0 })
  }

  /// mDNS can be spoofed: a service named for the paired device at another host is never used.
  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func pairingConnectsOnlyAtThePairingHost(withGenuine: Bool) async throws {
    let adb = FakeWirelessADB()
    let guid = "adb-PX8SERIAL-AbCdEf"
    let pixel = DeviceInfo(id: DeviceID(serial: "PX8SERIAL"), manufacturer: "", model: "Pixel 8")
    await adb.set {
      $0.pairOutcome = .paired(guid: guid)
      $0.mdns = [
        ADBMDNSService(
          name: guid, type: ADBMDNSService.connectType,
          endpoint: Self.endpoint("192.0.2.66:40000"))
      ]
      if withGenuine {
        $0.mdns.append(
          ADBMDNSService(
            name: guid, type: ADBMDNSService.connectType,
            endpoint: Self.endpoint("192.0.2.170:41235")))
      }
      $0.units["192.0.2.66:40000"] = .init(info: pixel)
      $0.units["192.0.2.170:41235"] = .init(info: pixel)
    }
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    let outcome = await wireless.pair(Self.endpoint("192.0.2.170:37123"), code: Self.code)
    #expect(outcome == (withGenuine ? .connected : .failed(.noConnectService)))
    #expect(!(await adb.calls.contains(.connect("192.0.2.66:40000"))))
  }

  @Test func hostsCompareAsAddresses() throws {
    let literal = try #require(WirelessEndpoint(parsing: "[2001:db8::5]:1"))
    #expect(literal.isSameHost(as: try #require(WirelessEndpoint(parsing: "[2001:DB8:0::5]:2"))))
    #expect(!literal.isSameHost(as: try #require(WirelessEndpoint(parsing: "[2001:db8::6]:1"))))
    let name = try #require(WirelessEndpoint(parsing: "Unit.lan:1"))
    #expect(name.isSameHost(as: try #require(WirelessEndpoint(parsing: "unit.LAN:2"))))
    #expect(!name.isSameHost(as: try #require(WirelessEndpoint(parsing: "10.0.0.1:1"))))
  }

  /// adb keeps a connection it could not use (offline, or listed in another form): Ferry drops it.
  @Test(.timeLimit(.minutes(1)))
  func aFailedConnectIsDisconnected() async throws {
    let adb = FakeWirelessADB()
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    _ = await wireless.connect(Self.endpoint("192.0.2.77"))
    #expect(await adb.calls == [.connect("192.0.2.77:5555"), .disconnect("192.0.2.77:5555")])
  }

  /// The question names the device as Ferry knows it, not as the claimant reports itself.
  @Test(.timeLimit(.minutes(1)))
  func consentTextComesFromFerryNotTheClaimant() async throws {
    let adb = FakeWirelessADB()
    let impostor = Self.endpoint("192.0.2.99")
    await adb.set {
      $0.units[impostor.argument] = .init(
        info: DeviceInfo(id: Self.etherScope.id, manufacturer: "", model: "Totally Legit"))
    }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      known: { [Self.etherScope.id: "EtherScope nXG"] })
    _ = await wireless.connect(impostor)
    #expect(await wireless.unconfirmed().map(\.name) == ["EtherScope nXG"])
  }

  @Test(.timeLimit(.minutes(1)))
  func theStoreIsReadableOnlyByTheUser() async throws {
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let adb = FakeWirelessADB()
    await adb.set { $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope) }
    _ = await WirelessADB(adb: adb, store: file, timing: Self.fast)
      .connect(Self.endpoint("192.0.2.31"))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o600)
  }
}
