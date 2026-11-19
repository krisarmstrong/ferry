import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing
import os

@testable import FerryAgentCore

/// A forget is never followed by an offer to confirm the address it just forgot.
@Suite(.timeLimit(.minutes(1)))
struct WirelessADBForgetOfferTests {
  static let fast = WirelessADBTests.fast
  static let linkRunner = WirelessADBTests.linkRunner
  static let address = WirelessADBTests.endpoint("192.0.2.40")

  /// A remembered, located device at `address`, with the vouching that serves it.
  private func remembered(_ adb: FakeWirelessADB) async throws -> (WirelessADB, WirelessVouching) {
    await adb.set { $0.units[Self.address.argument] = .init(info: Self.linkRunner) }
    let vouching = WirelessVouching()
    // Located once Ferry has made its Finder location, after the first connect.
    let located = OSAllocatedUnfairLock(initialState: false)
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      located: { id in
        id == Self.linkRunner.id && located.withLock { $0 } ? "LinkRunner-100G" : nil
      }, vouching: vouching)
    vouching.locate(identifiers: [], devices: [], complete: true)
    #expect(await wireless.connect(Self.address) == .connected)
    located.withLock { $0 = true }
    vouching.locate(identifiers: [], devices: [Self.linkRunner.id], complete: true)
    #expect(vouching.serves(Self.address.argument, as: Self.linkRunner.id))
    return (wireless, vouching)
  }

  /// While the forget disconnects the device, a scan finds its route neither vouched for nor
  /// refused: it is still being decided.
  @Test func aScanDuringTheForgetRaisesNoRefusal() async throws {
    let adb = FakeWirelessADB()
    let (wireless, vouching) = try await remembered(adb)
    let raised = OSAllocatedUnfairLock<[String]>(initialState: [])
    let listening = Task {
      for await refusal in vouching.refusals {
        raised.withLock { $0.append(refusal.adbSerial) }
      }
    }
    defer { listening.cancel() }
    await adb.holdDisconnects()
    let forgetting = Task { await wireless.forget(Self.linkRunner.id) }
    #expect(
      try await eventually { await adb.calls.contains(.disconnect(Self.address.argument)) })
    #expect(!vouching.serves(Self.address.argument, as: Self.linkRunner.id))
    await adb.releaseDisconnects()
    await forgetting.value
    // A refusal raised now arrives after any raised during the forget.
    let marker = "192.0.2.99:5555"
    #expect(!vouching.serves(marker, as: Self.linkRunner.id))
    #expect(try await eventually { raised.withLock { $0.contains(marker) } })
    #expect(raised.withLock { $0 } == [marker])
  }

  /// A refusal raised before the forget, and handled after it, is not offered.
  @Test func aRefusalForAForgottenDeviceIsDropped() async throws {
    let adb = FakeWirelessADB()
    let (wireless, vouching) = try await remembered(adb)
    // Only the offering of refusals runs: `run()` also polls mDNS through the gate.
    let offering = Task { await wireless.offerRefusedRoutes() }
    defer { offering.cancel() }
    // An unrelated connect holds the gate: it waits on the disconnect of its failed address.
    await adb.holdDisconnects()
    let busy = Task { await wireless.connect(WirelessADBTests.endpoint("192.0.2.50")) }
    #expect(try await eventually { await adb.calls.contains(.disconnect("192.0.2.50:5555")) })
    let forgetting = Task { await wireless.forget(Self.linkRunner.id) }
    #expect(try await eventually { await wireless.gate.waiting == 1 })
    let claimant = "192.0.2.41:5555"
    #expect(!vouching.serves(claimant, as: Self.linkRunner.id))
    #expect(try await eventually { await wireless.gate.waiting == 2 })
    await adb.releaseDisconnects()
    _ = await busy.value
    await forgetting.value
    // Queued behind the offer: once this has run, so has the offer.
    await wireless.ignore(WirelessADBTests.endpoint("192.0.2.60"))
    #expect(await wireless.unconfirmed().isEmpty)
  }

  /// A refusal raised before a forget and taken off the stream only after the forget has
  /// finished is dropped too; the route may be raised, and offered, again on a later scan.
  @Test func aRefusalReadAfterAWholeForgetIsDropped() async throws {
    let adb = FakeWirelessADB()
    let (wireless, vouching) = try await remembered(adb)
    let claimant = "192.0.2.41:5555"
    #expect(!vouching.serves(claimant, as: Self.linkRunner.id))
    await wireless.forget(Self.linkRunner.id)
    // Raised after the forget, so offered: refusals are handled in order, so once it is on
    // offer the first has been handled.
    let marker = "192.0.2.42:5555"
    #expect(!vouching.serves(marker, as: Self.linkRunner.id))
    let offering = Task { await wireless.offerRefusedRoutes() }
    defer { offering.cancel() }
    #expect(try await eventually { await !wireless.unconfirmed().isEmpty })
    #expect(await wireless.unconfirmed().map(\.address.argument) == [marker])
    // Not reported for good: a later scan raises it again, and it is offered.
    #expect(!vouching.serves(claimant, as: Self.linkRunner.id))
    #expect(
      try await eventually { await wireless.unconfirmed().map(\.address.argument).count == 2 })
  }
}
