import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// Fix round 1: the hub serves a network address only when WirelessADB vouches for it or the
/// device is unknown to Ferry and settled; identity reads fail closed; deferred adoption and
/// confirmation are checked against what is true when they happen; startup reconnects never
/// hold up the user.
struct WirelessADBFixRoundTests {
  static let etherScope = WirelessADBTests.etherScope
  static let linkRunner = WirelessADBTests.linkRunner
  static let fast = WirelessADBTests.fast
  static let impostor = WirelessEndpoint(parsing: "192.0.2.99")!
  static let stranger = DeviceInfo(
    id: DeviceID(serial: "NEWUNIT1"), manufacturer: "", model: "New unit")

  static func endpoint(_ text: String) -> WirelessEndpoint { WirelessADBTests.endpoint(text) }

  static func remembering(_ adb: FakeWirelessADB, _ file: URL) async {
    await adb.set { $0.units["192.0.2.31:5555"] = .init(info: Self.etherScope) }
    _ = await WirelessADB(adb: adb, store: file, timing: Self.fast)
      .connect(Self.endpoint("192.0.2.31"))
    await adb.set { $0.listed = [:] }
  }

  // MARK: Serving

  @Test(.timeLimit(.minutes(1)))
  func onlyVouchedAddressesOfRememberedDevicesAreServed() async throws {
    let adb = FakeWirelessADB()
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await Self.remembering(adb, file)
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast, vouching: vouching)
    #expect(vouching.serves("192.0.2.31:5555", as: Self.etherScope.id))
    #expect(!vouching.serves(Self.impostor.argument, as: Self.etherScope.id))
    // Unknown to Ferry: a terminal `adb connect` to a new device still works.
    #expect(vouching.serves("192.0.2.50:5555", as: Self.stranger.id))
    await wireless.forget(Self.etherScope.id)
    #expect(vouching.serves(Self.impostor.argument, as: Self.etherScope.id))
  }

  /// The race: a scan that sees the address while WirelessADB is still deciding must not serve
  /// it, even for a device Ferry does not know; once remembered it is served.
  @Test(.timeLimit(.minutes(1)))
  func anAddressIsNotServedWhileItsIdentityIsUnsettled() async throws {
    let adb = FakeWirelessADB()
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    let seen = Mutex<[Bool]>([])
    let address = Self.endpoint("192.0.2.50")
    await adb.set {
      $0.units[address.argument] = .init(info: Self.stranger)
      $0.whileIdentifying = { serial in
        seen.withLock { $0.append(vouching.serves(serial, as: Self.stranger.id)) }
      }
    }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast, vouching: vouching)
    #expect(await wireless.connect(address) == .connected)
    #expect(seen.withLock { $0 } == [false])
    #expect(vouching.serves(address.argument, as: Self.stranger.id))
  }

  /// adb sends no event when Ferry decides, so the hub is told to scan again: an address held
  /// back while it was being decided is served without waiting for some unrelated change.
  @Test(.timeLimit(.minutes(1)))
  func decidingTellsTheHubToScanAgain() async throws {
    let adb = FakeWirelessADB()
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    let address = Self.endpoint("192.0.2.50")
    await adb.set { $0.units[address.argument] = .init(info: Self.stranger) }
    let ticks = Mutex(0)
    let follower = Task {
      for await _ in vouching.changes { ticks.withLock { $0 += 1 } }
    }
    defer { follower.cancel() }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast, vouching: vouching)
    #expect(await wireless.connect(address) == .connected)
    #expect(try await eventually { ticks.withLock { $0 } > 0 })
  }

  @Test(.timeLimit(.minutes(1)))
  func aWaitingAddressIsNotServed() async throws {
    let adb = FakeWirelessADB()
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    let address = Self.endpoint("192.0.2.50")
    await adb.set { $0.units[address.argument] = .init(info: Self.stranger, authorized: false) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast, vouching: vouching)
    #expect(await wireless.connect(address) == .awaitingAllow(address))
    #expect(!vouching.serves(address.argument, as: Self.stranger.id))
  }

  // MARK: Failing closed

  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func aDeviceThatCannotBeIdentifiedIsDisconnected(throwing: Bool) async throws {
    let adb = FakeWirelessADB()
    let address = Self.endpoint("192.0.2.50")
    await adb.set {
      $0.units[address.argument] = .init(info: Self.stranger)
      if throwing {
        $0.unreadable = [address.argument]
      } else {
        $0.nameless = [address.argument]
      }
    }
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [], complete: true)
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast, vouching: vouching)
    let outcome = await wireless.connect(address)
    #expect(outcome == .failed(.unidentified))
    #expect(await adb.calls.last == .disconnect(address.argument))
    #expect(await wireless.remembered().isEmpty)
  }

  // MARK: Deferred adoption

  /// Unknown when the connect started, but the hub serves the device (over USB) by the time the
  /// user taps Allow: it is offered, not adopted.
  @Test(.timeLimit(.minutes(1)))
  func aWaitingAddressIsCheckedAgainstWhatIsKnownWhenItResolves() async throws {
    let adb = FakeWirelessADB()
    let served = Mutex<[DeviceID: String]>([:])
    let address = Self.endpoint("192.0.2.40")
    await adb.set {
      $0.units[address.argument] = .init(info: Self.etherScope, authorized: false)
    }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      known: { served.withLock { $0 } })
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    #expect(await wireless.connect(address) == .awaitingAllow(address))
    served.withLock { $0 = [Self.etherScope.id: "EtherScope nXG"] }
    await adb.set {
      $0.units[address.argument]?.authorized = true
      $0.listed[address.argument] = .device
    }
    await adb.publish()
    #expect(try await eventually { await !wireless.unconfirmed().isEmpty })
    #expect(await wireless.remembered().isEmpty)
    #expect(await adb.calls.last == .disconnect(address.argument))
  }

  // MARK: Consent

  @Test(.timeLimit(.minutes(1)))
  func confirmingNeedsTheOfferExactlyAsShown() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.units[Self.impostor.argument] = .init(info: Self.etherScope) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      known: { [Self.etherScope.id: "EtherScope nXG"] })
    _ = await wireless.connect(Self.impostor)
    let shown = try #require(await wireless.unconfirmed().first)
    let otherDevice = UnconfirmedAddress(
      address: Self.impostor, id: Self.linkRunner.id, name: shown.name)
    let otherName = UnconfirmedAddress(address: Self.impostor, id: shown.id, name: "Other")
    #expect(await wireless.confirm(otherDevice) == .failed(.offerChanged))
    #expect(await wireless.confirm(otherName) == .failed(.offerChanged))
    #expect(await wireless.unconfirmed() == [shown])
    #expect(await wireless.confirm(shown) == .connected)
  }

  /// An address that claims one device, then another, is not trusted as either.
  @Test(.timeLimit(.minutes(1)))
  func anOfferIsNeverReplacedByAnotherDevice() async throws {
    let adb = FakeWirelessADB()
    await adb.set { $0.units[Self.impostor.argument] = .init(info: Self.etherScope) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      known: { [Self.etherScope.id: "EtherScope nXG", Self.linkRunner.id: "LinkRunner-100G"] })
    _ = await wireless.connect(Self.impostor)
    await adb.set { $0.units[Self.impostor.argument] = .init(info: Self.linkRunner) }
    _ = await wireless.connect(Self.impostor)
    #expect(await wireless.unconfirmed().isEmpty)
  }

  // MARK: Startup reconnects

  /// Six remembered devices whose addresses do not answer: they are tried at most four at a
  /// time, and a Connect by the user meanwhile does not wait for them.
  @Test(.timeLimit(.minutes(1)))
  func startupReconnectsAreBoundedAndNeverBlockTheUser() async throws {
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let devices = (1...6).map { index in
      #""U\#(index)":{"name":"Unit","addresses":[{"address":"203.0.113.\#(index):5555","learnt":"user"}]}"#
    }
    try Data(#"{"devices":{\#(devices.joined(separator: ","))}}"#.utf8).write(to: file)
    let adb = FakeWirelessADB()
    let address = Self.endpoint("192.0.2.50")
    await adb.set {
      for index in 1...6 { $0.connectDelay["203.0.113.\(index):5555"] = .seconds(2) }
      $0.units[address.argument] = .init(info: Self.stranger)
    }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(try await eventually { await adb.inFlight >= 4 })
    let started = ContinuousClock.now
    #expect(await wireless.connect(address) == .connected)
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(
      try await eventually {
        await adb.calls.filter { if case .connect = $0 { true } else { false } }.count == 7
      })
    // Four reconnects at once, plus the user's own connect.
    #expect(await adb.maxInFlight <= 5)
  }
}
