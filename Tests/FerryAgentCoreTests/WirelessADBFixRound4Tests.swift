import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// Fix round 4: an incomplete location set fails closed; a route refused because its device has
/// a Finder location is offered to the user; and the minors.
struct WirelessADBFixRound4Tests {
  static let fast = WirelessADBTests.fast
  static let address = "192.0.2.40:5555"
  static let stranger = DeviceID(serial: "NEWUNIT1")
  static let located = DeviceID(serial: "0123456789abcdef")

  static func existingLocation() -> String {
    DomainNaming.identifier(for: StorageID(device: located, key: "internal"))
  }

  // MARK: N1

  /// The system's domains could not be listed: until a retry succeeds the location set is
  /// incomplete, so only vouched routes are served and a typed address for any serial that is not
  /// remembered is offered, never adopted.
  @Test(.timeLimit(.minutes(1)))
  func aFailedListingKeepsLocationsIncompleteUntilARetrySucceeds() async throws {
    let manager = FakeDomainManager(existing: [Self.existingLocation()], listingFailures: 1)
    let harness = try AgentHarness(manager: manager)
    defer { harness.finish() }
    let vouching = WirelessVouching()
    vouching.remember([:])
    await harness.controller.publishLocations(to: vouching)
    #expect(await harness.controller.location(of: Self.stranger) != nil)
    #expect(!vouching.serves(Self.address, as: Self.stranger))
    #expect(!vouching.serves(Self.address, as: Self.located))

    let adb = FakeWirelessADB()
    let typed = WirelessADBTests.endpoint("192.0.2.40")
    await adb.set {
      $0.units[typed.argument] = .init(
        info: DeviceInfo(id: Self.stranger, manufacturer: "", model: "New"))
    }
    let controller = harness.controller
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      located: { await controller.location(of: $0) })
    #expect(await wireless.connect(typed) == .needsConfirmation(typed))

    // The retry lists the domains: the set is complete and exact from then on.
    #expect(
      try await eventually(timeout: .seconds(20)) {
        vouching.serves(Self.address, as: Self.stranger)
      })
    #expect(!vouching.serves(Self.address, as: Self.located))
    #expect(await harness.controller.location(of: Self.stranger) == nil)
    #expect(await harness.controller.location(of: Self.located) != nil)
  }

  /// A location asked for before the system's domains are adopted waits for them.
  @Test(.timeLimit(.minutes(1)))
  func aLocationAskedForBeforeAdoptionWaitsForIt() async throws {
    let manager = FakeDomainManager(existing: [Self.existingLocation()])
    await manager.holdExisting()
    let harness = try AgentHarness(manager: manager)
    defer { harness.finish() }
    let answered = Mutex<String??>(nil)
    let asking = Task {
      let name = await harness.controller.location(of: Self.located)
      answered.withLock { $0 = .some(name) }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(answered.withLock { $0 } == nil)
    await manager.releaseExisting()
    await asking.value
    #expect(answered.withLock { $0 }.flatMap { $0 } != nil)
  }

  // MARK: N2

  /// A route refused because its device has a Finder location is offered, once, by the
  /// location's name.
  @Test(.timeLimit(.minutes(1)))
  func aRouteRefusedForALocatedDeviceIsOffered() async throws {
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [Self.existingLocation()], devices: [], complete: true)
    let adb = FakeWirelessADB()
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      located: { $0 == Self.located ? "LinkRunner-100G" : nil }, vouching: vouching)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(!vouching.serves(Self.address, as: Self.located))
    #expect(!vouching.serves(Self.address, as: Self.located))
    let endpoint = WirelessADBTests.endpoint(Self.address)
    #expect(
      try await eventually {
        await wireless.unconfirmed()
          == [UnconfirmedAddress(address: endpoint, id: Self.located, name: "LinkRunner-100G")]
      })
    // Never connected to: the user's Use it does that.
    #expect(await adb.calls.isEmpty)
  }

  /// A route refused for any other reason (not loaded, being decided) offers nothing.
  @Test(.timeLimit(.minutes(1)))
  func otherRefusalsOfferNothing() async throws {
    let vouching = WirelessVouching()
    let wireless = WirelessADB(
      adb: FakeWirelessADB(), store: WirelessADBTests.storeFile(), timing: Self.fast,
      located: { _ in "LinkRunner-100G" }, vouching: vouching)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(!vouching.serves(Self.address, as: Self.located))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await wireless.unconfirmed().isEmpty)
  }

  // MARK: Minors

  /// n2: a connect that throws (adb timed out) may still finish in the server: it is dropped.
  @Test(.timeLimit(.minutes(1)))
  func aConnectThatThrowsIsDisconnected() async throws {
    let adb = FakeWirelessADB()
    let typed = WirelessADBTests.endpoint("192.0.2.40")
    await adb.set { $0.connectThrows = [typed.argument] }
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    _ = await wireless.connect(typed)
    #expect(await adb.calls == [.connect(typed.argument), .disconnect(typed.argument)])
  }

  /// n3: a reconnect planned before a forget does not touch the device the user added again.
  @Test(.timeLimit(.minutes(1)))
  func aStaleReconnectLeavesADeviceAddedAgainAlone() async throws {
    let adb = FakeWirelessADB()
    let etherScope = WirelessADBTests.etherScope
    let typed = WirelessADBTests.endpoint("192.0.2.31")
    await adb.set { $0.units[typed.argument] = .init(info: etherScope) }
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    _ = await wireless.connect(typed)
    let since = await wireless.forgets
    await wireless.forget(etherScope.id)
    #expect(await wireless.connect(typed) == .connected)
    let entry = try #require(await wireless.entries[etherScope.id])
    let callsBefore = await adb.calls.count
    _ = await wireless.reconnect(etherScope.id, entry, since: since)
    #expect(await adb.calls.count == callsBefore)
    #expect(await wireless.remembered().map(\.id) == [etherScope.id])
  }

  /// n5: Remove Ferry also forgets every remembered device and disconnects it.
  @Test(.timeLimit(.minutes(1)))
  func removingFerryForgetsRememberedDevices() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    let adb = FakeWirelessADB()
    let typed = WirelessADBTests.endpoint("192.0.2.31")
    await adb.set { $0.units[typed.argument] = .init(info: WirelessADBTests.etherScope) }
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    let service = AgentService(
      hub: harness.hub, domains: harness.controller, scratch: harness.scratch, wireless: wireless)
    _ = await service.handle(.connectAddress(typed), file: nil)
    _ = await service.handle(.removeAllDomains, file: nil)
    #expect(await wireless.remembered().isEmpty)
    #expect(await adb.calls.last == .disconnect(typed.argument))
  }

  /// n6: pairing compares the connect service's address with the pairing address, which must
  /// therefore be the IP address the device shows, not a name.
  @Test(.timeLimit(.minutes(1)))
  func pairingNeedsTheIPAddressTheDeviceShows() async throws {
    let adb = FakeWirelessADB()
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    let named = try #require(WirelessEndpoint(parsing: "pixel.lan:37123", defaultPort: nil))
    #expect(
      await wireless.pair(named, code: PairingCode("482913")!) == .failed(.pairingNeedsAddress))
    #expect(await adb.calls.isEmpty)
    #expect(try #require(WirelessEndpoint(parsing: "10.0.0.5:1")).isAddressLiteral)
    #expect(!named.isAddressLiteral)
  }
}
