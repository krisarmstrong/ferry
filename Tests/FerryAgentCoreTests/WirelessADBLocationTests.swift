import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A device with a Finder location is known to Ferry even while it is unplugged: a typed address
/// claiming its serial is offered for confirmation, never adopted, so it cannot take over that
/// location.
struct WirelessADBLocationTests {
  static let fast = WirelessADBTests.fast
  static let linkRunner = WirelessADBTests.linkRunner

  @Test(.timeLimit(.minutes(1)))
  func aDeviceWithALocationIsKnownWhileUnplugged() async throws {
    let device = await makeDevice("LR1", model: "LinkRunner")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    #expect(await harness.controller.location(of: device.info.id) == "LinkRunner")
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)
    #expect(await harness.controller.location(of: device.info.id) == "LinkRunner")
    #expect(await harness.controller.location(of: DeviceID(serial: "NEVERSEEN")) == nil)
  }

  /// After a restart the agent knows its domains only by identifier, a hash of serial and
  /// storage key: a claimed serial is checked by hashing it with the internal storage's keys.
  @Test(.timeLimit(.minutes(1)), arguments: ["internal", "Internal shared storage|"])
  func aDomainFromBeforeTheRestartIsFoundByItsInternalStorage(key: String) async throws {
    let id = DeviceID(serial: "0123456789abcdef")
    let existing = DomainNaming.identifier(for: StorageID(device: id, key: key))
    let harness = try AgentHarness(existing: [existing])
    defer { harness.finish() }
    #expect(try await eventually { await harness.controller.location(of: id) != nil })
    #expect(await harness.controller.location(of: DeviceID(serial: "NEVERSEEN")) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func aTypedAddressClaimingALocatedDeviceIsOffered() async throws {
    let adb = FakeWirelessADB()
    let address = WirelessADBTests.endpoint("192.0.2.40")
    await adb.set { $0.units[address.argument] = .init(info: Self.linkRunner) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast,
      located: { $0 == Self.linkRunner.id ? "LinkRunner-100G" : nil })
    #expect(await wireless.connect(address) == .needsConfirmation(address))
    #expect(await wireless.remembered().isEmpty)
    #expect(await wireless.unconfirmed().map(\.name) == ["LinkRunner-100G"])
    #expect(await adb.calls.last == .disconnect(address.argument))
  }

  @Test(.timeLimit(.minutes(1)))
  func aTypedAddressForAnUnknownSerialIsAdoptedAsBefore() async throws {
    let adb = FakeWirelessADB()
    let address = WirelessADBTests.endpoint("192.0.2.40")
    await adb.set { $0.units[address.argument] = .init(info: Self.linkRunner) }
    let wireless = WirelessADB(
      adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast, located: { _ in nil })
    #expect(await wireless.connect(address) == .connected)
    #expect(await wireless.remembered().map(\.id) == [Self.linkRunner.id])
  }
}
