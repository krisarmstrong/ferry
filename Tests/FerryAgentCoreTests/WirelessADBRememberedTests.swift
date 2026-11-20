import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Devices remembered by serial: reconnected at start, when the server returns and when adb's
/// mDNS lists them; forgotten on request; read back from a file that is validated again.
struct WirelessADBRememberedTests {
  static let etherScope = WirelessADBTests.etherScope
  static let linkRunner = WirelessADBTests.linkRunner
  static let fast = WirelessADBTests.fast

  static func endpoint(_ text: String) -> WirelessEndpoint { WirelessADBTests.endpoint(text) }
  static func storeFile() -> URL { WirelessADBTests.storeFile() }

  static func rememberEtherScope(_ adb: FakeWirelessADB, _ file: URL) async {
    await adb.set { $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope) }
    let first = WirelessADB(adb: adb, store: file, timing: Self.fast)
    _ = await first.connect(Self.endpoint("192.0.2.31"))
    await adb.set { $0.listed = [:] }
  }

  @Test(.timeLimit(.minutes(1)))
  func rememberedDevicesReconnectWhenTheAgentStarts() async throws {
    let adb = FakeWirelessADB()
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    let restarted = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await restarted.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(
      try await eventually {
        await adb.calls.filter { $0 == .connect("192.0.2.31:5555") }.count == 2
      })
  }

  /// adb's server holds the network connections: after `adb kill-server` they are gone, and
  /// come back when the server does.
  @Test(.timeLimit(.minutes(1)))
  func rememberedDevicesReconnectWhenTheServerComesBack() async throws {
    let adb = FakeWirelessADB()
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    await adb.set { $0.listed["192.0.2.31:5555"] = .device }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    // Listed already: nothing to do.
    try await Task.sleep(for: .milliseconds(50))
    #expect(await adb.calls.filter { $0 == .connect("192.0.2.31:5555") }.count == 1)
    await adb.serverGone()
    await adb.set { $0.listed = [:] }
    await adb.publish()
    #expect(
      try await eventually {
        await adb.calls.filter { $0 == .connect("192.0.2.31:5555") }.count == 2
      })
  }

  /// A device paired with a code moves ports. adb's mDNS listing it under its serial at a new
  /// address proves nothing (anyone can advertise a name), so the address is offered for the
  /// user to confirm, never connected on its own; once confirmed it is connected and checked.
  @Test(.timeLimit(.minutes(1)))
  func anAddressMDNSListsForARememberedDeviceIsOfferedNotConnected() async throws {
    let adb = FakeWirelessADB()
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    await adb.set { $0.units["192.0.2.31:5555"] = nil }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    let offered = Self.endpoint("192.0.2.170:41001")
    await adb.set {
      $0.mdns = [
        ADBMDNSService(
          name: "adb-\(Self.etherScope.id.serial)-Q1", type: "_adb-tls-connect._tcp",
          endpoint: offered),
        ADBMDNSService(
          name: "adb-SOMEONE-ELSE-Q2", type: "_adb-tls-connect._tcp",
          endpoint: Self.endpoint("192.0.2.177:41002")),
      ]
      $0.units["192.0.2.170:41001"] = .init(info: Self.etherScope)
    }
    #expect(
      try await eventually {
        await wireless.unconfirmed()
          == [UnconfirmedAddress(address: offered, id: Self.etherScope.id, name: "EtherScope nXG")]
      })
    try await Task.sleep(for: .milliseconds(60))
    #expect(!(await adb.calls.contains(.connect("192.0.2.170:41001"))))
    #expect(!(await adb.calls.contains(.connect("192.0.2.177:41002"))))
    let offer = try #require(await wireless.unconfirmed().first)
    #expect(await wireless.confirm(offer) == .connected)
    #expect(await adb.calls.contains(.connect("192.0.2.170:41001")))
    #expect(await wireless.remembered().first?.addresses.first == offered)
    #expect(await wireless.unconfirmed().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func forgetDisconnectsAndRemoves() async throws {
    let adb = FakeWirelessADB()
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    await wireless.forget(Self.etherScope.id)
    #expect(await adb.calls.last == .disconnect("192.0.2.31:5555"))
    #expect(await wireless.remembered().isEmpty)
    #expect(await WirelessADB(adb: adb, store: file, timing: Self.fast).remembered().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectAgainUsesTheRememberedAddresses() async throws {
    let adb = FakeWirelessADB()
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(await wireless.reconnect(Self.etherScope.id) == .connected)
    #expect(await wireless.reconnect(Self.linkRunner.id) == .failed(.notRemembered))
  }

  /// A stored address that is not one (edited by hand, or written by a bug) never reaches adb.
  @Test(.timeLimit(.minutes(1)))
  func storedAddressesAreValidatedAgainOnLoad() async throws {
    let file = Self.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let stored = """
      {"devices":{"fedcba9876543210":{"name":"EtherScope nXG","addresses":[\
      {"address":"-s","learnt":"user"},{"address":"192.0.2.31:5555","learnt":"user"},\
      {"address":"host;rm:5555","learnt":"user"}]}}}
      """
    try Data(stored.utf8).write(to: file)
    let adb = FakeWirelessADB()
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(
      await wireless.remembered().first?.addresses == [Self.endpoint("192.0.2.31:5555")])
  }

  /// An unreadable store is moved aside, not overwritten, so the user's devices can be got
  /// back; for this run only vouched routes are served, as the remembered set is unknown.
  @Test(.timeLimit(.minutes(1)))
  func anUnreadableStoreIsKeptAsideAndServesOnlyVouchedRoutes() async throws {
    let folder = TestScratch.root.appending(path: "ferry-wireless-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "wireless.json")
    try Data("not json".utf8).write(to: file)
    let vouching = WirelessVouching()
    let wireless = WirelessADB(
      adb: FakeWirelessADB(), store: file, timing: Self.fast, vouching: vouching)
    #expect(await wireless.remembered().isEmpty)
    let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(kept.count == 1)
    #expect(kept.first?.hasPrefix("wireless.json.unreadable-") == true)
    #expect(
      try Data(contentsOf: folder.appending(path: try #require(kept.first)))
        == Data("not json".utf8))
    vouching.locate(identifiers: [], devices: [], complete: true)
    #expect(!vouching.serves("192.0.2.31:5555", as: DeviceID(serial: "NEWUNIT1")))
  }
}

struct AgentWirelessTests {
  @Test(.timeLimit(.minutes(1)))
  func wirelessRequestsReachWirelessADBAndStatusListsRemembered() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let adb = FakeWirelessADB()
    await adb.set {
      $0.units["192.0.2.31:5555"] = .init(info: WirelessADBTests.etherScope)
    }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: WirelessADBTests.fast)
    let service = AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch, wireless: wireless)
    let address = WirelessADBTests.endpoint("192.0.2.31")
    #expect(await service.handle(.connectAddress(address), file: nil) == .wireless(.connected))
    guard case .status(let report) = await service.handle(.status, file: nil) else {
      Issue.record("no status")
      return
    }
    #expect(report.remembered.map(\.id) == [WirelessADBTests.etherScope.id])
    #expect(
      await service.handle(.forgetWireless(WirelessADBTests.etherScope.id), file: nil) == .done)
    #expect(await wireless.remembered().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func withoutAdbWirelessRequestsAreUnsupported() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let address = WirelessADBTests.endpoint("192.0.2.31")
    #expect(
      await harness.service.handle(.connectAddress(address), file: nil)
        == .wireless(.failed(.adbUnavailable)))
  }
}
