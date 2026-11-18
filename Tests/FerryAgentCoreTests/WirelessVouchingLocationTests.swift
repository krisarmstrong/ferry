import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The serving check treats a device with a Finder location as known: a network route that
/// claims an unplugged, located device and that Ferry has not vouched for (a terminal
/// `adb connect`) is never served. Until the domain controller has published its locations,
/// nothing on the network is served.
struct WirelessVouchingLocationTests {
  static let address = "192.0.2.40:5555"

  @Test func nothingIsServedUntilLocationsArePublished() {
    let vouching = WirelessVouching()
    vouching.remember([:])
    #expect(!vouching.serves(Self.address, as: DeviceID(serial: "NEWUNIT1")))
    vouching.locate(identifiers: [], devices: [], complete: true)
    #expect(vouching.serves(Self.address, as: DeviceID(serial: "NEWUNIT1")))
  }

  @Test(arguments: ["internal", "Internal shared storage|"])
  func aLocationFromBeforeTheRestartIsFoundByHashingTheClaimedSerial(key: String) {
    let located = DeviceID(serial: "0123456789abcdef")
    let vouching = WirelessVouching()
    vouching.remember([:])
    vouching.locate(
      identifiers: [DomainNaming.identifier(for: StorageID(device: located, key: key))],
      devices: [], complete: true)
    #expect(!vouching.serves(Self.address, as: located))
    #expect(vouching.serves(Self.address, as: DeviceID(serial: "NEWUNIT1")))
  }

  @Test func aLocatedDeviceIsNotServedUnvouchedButIsAtAVouchedAddress() throws {
    let located = DeviceID(serial: "LR1")
    let vouching = WirelessVouching()
    vouching.locate(identifiers: [], devices: [located], complete: true)
    let vouched = try #require(WirelessEndpoint(parsing: Self.address))
    vouching.remember([
      located: WirelessADB.Entry(name: "LR", addresses: [.init(endpoint: vouched, learnt: .user)])
    ])
    #expect(vouching.serves(Self.address, as: located))
    #expect(!vouching.serves("192.0.2.41:5555", as: located))
  }

  /// The domain controller publishes its locations once it has adopted the system's domains, and
  /// again whenever they change; a device keeps its location when unplugged.
  @Test(.timeLimit(.minutes(1)))
  func theDomainControllerKeepsTheLocationsCurrent() async throws {
    let device = await makeDevice("LR1", model: "LinkRunner")
    let harness = try AgentHarness()
    defer { harness.finish() }
    let vouching = WirelessVouching()
    vouching.remember([:])
    await harness.controller.publishLocations(to: vouching)
    #expect(try await eventually { vouching.serves(Self.address, as: device.info.id) })
    await harness.transport.attach(device)
    harness.tick()
    _ = await harness.manager.waitForCalls(1)
    #expect(try await eventually { !vouching.serves(Self.address, as: device.info.id) })
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)
    #expect(!vouching.serves(Self.address, as: device.info.id))
    #expect(vouching.serves(Self.address, as: DeviceID(serial: "NEWUNIT1")))
  }

  /// At agent start the locations are those the system already has, known only by identifier.
  @Test(.timeLimit(.minutes(1)))
  func locationsFromBeforeTheRestartArePublished() async throws {
    let located = DeviceID(serial: "0123456789abcdef")
    let existing = DomainNaming.identifier(for: StorageID(device: located, key: "internal"))
    let harness = try AgentHarness(existing: [existing])
    defer { harness.finish() }
    let vouching = WirelessVouching()
    vouching.remember([:])
    await harness.controller.publishLocations(to: vouching)
    #expect(
      try await eventually { vouching.serves(Self.address, as: DeviceID(serial: "NEWUNIT1")) })
    #expect(!vouching.serves(Self.address, as: located))
  }
}
