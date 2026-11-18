import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// adb's key authorisation does not authenticate a device over plain TCP: any host can claim a
/// serial. So a new address for a serial Ferry already knows is never merged or served on its
/// own, and only addresses the user confirmed or that were read over USB are reconnected.
struct WirelessADBTrustTests {
  static let etherScope = WirelessADBTests.etherScope
  static let fast = WirelessADBTests.fast
  static let impostor = WirelessEndpoint(parsing: "192.0.2.99")!

  static func endpoint(_ text: String) -> WirelessEndpoint { WirelessADBTests.endpoint(text) }

  static func rememberEtherScope(_ adb: FakeWirelessADB, _ file: URL) async {
    await adb.set { $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope) }
    _ = await WirelessADB(adb: adb, store: file, timing: Self.fast)
      .connect(Self.endpoint("192.0.2.31"))
    await adb.set { $0.listed = [:] }
  }

  /// A host typed by the user that claims the serial of a unit on USB is dropped and offered.
  @Test(.timeLimit(.minutes(1)))
  func aTypedAddressClaimingAUnitOnUSBNeedsConfirmation() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.units[Self.impostor.argument] = .init(info: Self.etherScope) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      known: { [Self.etherScope.id: "EtherScope nXG"] })
    #expect(await wireless.connect(Self.impostor) == .needsConfirmation(Self.impostor))
    #expect(await adb.calls == [.connect("192.0.2.99:5555"), .disconnect("192.0.2.99:5555")])
    #expect(await wireless.remembered().isEmpty)
    #expect(
      await wireless.unconfirmed() == [
        UnconfirmedAddress(address: Self.impostor, id: Self.etherScope.id, name: "EtherScope nXG")
      ])
  }

  /// The poisoning the review found: the new address must not join the remembered entry.
  @Test(.timeLimit(.minutes(1)))
  func aTypedAddressClaimingARememberedSerialIsNotMerged() async throws {
    let adb = FakeWirelessADB()
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    await adb.set { $0.units[Self.impostor.argument] = .init(info: Self.etherScope) }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(await wireless.connect(Self.impostor) == .needsConfirmation(Self.impostor))
    #expect(
      await wireless.remembered().first?.addresses == [Self.endpoint("192.0.2.31:5555")])
    #expect(await adb.calls.last == .disconnect("192.0.2.99:5555"))
  }

  @Test(.timeLimit(.minutes(1)))
  func confirmingJoinsTheEntryAndIgnoringDropsIt() async throws {
    let adb = FakeWirelessADB()
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    let other = Self.endpoint("192.0.2.98")
    await adb.set {
      $0.units[Self.impostor.argument] = .init(info: Self.etherScope)
      $0.units[other.argument] = .init(info: Self.etherScope)
    }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    _ = await wireless.connect(Self.impostor)
    _ = await wireless.connect(other)
    let offers = await wireless.unconfirmed()
    let impostorOffer = try #require(offers.first { $0.address == Self.impostor })
    let otherOffer = try #require(offers.first { $0.address == other })
    #expect(await wireless.confirm(impostorOffer) == .connected)
    await wireless.ignore(other)
    #expect(await wireless.unconfirmed().isEmpty)
    #expect(
      await wireless.remembered().first?.addresses == [
        Self.impostor, Self.endpoint("192.0.2.31:5555"),
      ])
    #expect(await wireless.confirm(otherOffer) == .failed(.offerChanged))
  }

  /// A confirmed address must still answer as the device it was offered for.
  @Test(.timeLimit(.minutes(1)))
  func aConfirmedAddressMustStillAnswerAsTheDevice() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.units[Self.impostor.argument] = .init(info: Self.etherScope) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      known: { [Self.etherScope.id: "EtherScope nXG"] })
    _ = await wireless.connect(Self.impostor)
    let offer = try #require(await wireless.unconfirmed().first)
    await adb.set { $0.units[Self.impostor.argument] = .init(info: WirelessADBTests.linkRunner) }
    #expect(await wireless.confirm(offer) == .failed(.otherDevice))
    #expect(await wireless.remembered().isEmpty)
  }

  /// Only addresses the user gave or confirmed, or that were read over USB, are reconnected.
  @Test(.timeLimit(.minutes(1)))
  func onlyUserOrUSBAddressesAreReconnected() async throws {
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let stored = """
      {"devices":{"fedcba9876543210":{"name":"EtherScope nXG","addresses":[\
      {"address":"192.0.2.169:41001","learnt":"paired"},\
      {"address":"192.0.2.31:5555","learnt":"user"},\
      {"address":"192.0.2.166:5555","learnt":"usb"}]}}}
      """
    try Data(stored.utf8).write(to: file)
    let adb = FakeWirelessADB()
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(
      try await eventually {
        await adb.calls.filter { if case .connect = $0 { true } else { false } }.count == 2
      })
    let calls = await adb.calls
    #expect(calls.contains(.connect("192.0.2.31:5555")))
    #expect(calls.contains(.connect("192.0.2.166:5555")))
    #expect(!calls.contains(.connect("192.0.2.169:41001")))
  }

  /// Forgetting revokes everything under way: a connection waiting for Allow at one of its
  /// addresses is dropped and disconnected, and never remembered once allowed.
  @Test(.timeLimit(.minutes(1)))
  func forgetDropsWaitingConnectionsAtItsAddresses() async throws {
    let adb = FakeWirelessADB()
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.rememberEtherScope(adb, file)
    await adb.set { $0.units["192.0.2.31:5555"]?.authorized = false }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(
      await wireless.reconnect(Self.etherScope.id)
        == .awaitingAllow(Self.endpoint("192.0.2.31:5555")))
    await wireless.forget(Self.etherScope.id)
    #expect(await adb.calls.last == .disconnect("192.0.2.31:5555"))
    await adb.set {
      $0.units["192.0.2.31:5555"]?.authorized = true
      $0.listed["192.0.2.31:5555"] = .device
    }
    await adb.publish()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await wireless.remembered().isEmpty)
  }

  /// A waiting connection at an address the forgotten device never had is re-checked when it
  /// resolves: it answers as the forgotten device, so it is dropped, not remembered.
  @Test(.timeLimit(.minutes(1)))
  func aWaitingConnectionResolvingAsAForgottenDeviceIsDropped() async throws {
    let adb = FakeWirelessADB()
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let elsewhere = Self.endpoint("192.0.2.40")
    await adb.set {
      $0.units[elsewhere.argument] = .init(info: Self.etherScope, authorized: false)
    }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(await wireless.connect(elsewhere) == .awaitingAllow(elsewhere))
    await wireless.forget(Self.etherScope.id)
    await adb.set {
      $0.units[elsewhere.argument]?.authorized = true
      $0.listed[elsewhere.argument] = .device
    }
    await adb.publish()
    #expect(try await eventually { await adb.calls.last == .disconnect("192.0.2.40:5555") })
    #expect(await wireless.remembered().isEmpty)
  }
}
