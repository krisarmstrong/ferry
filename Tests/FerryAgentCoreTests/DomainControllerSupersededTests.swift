import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryAgentCore

/// A domain from before method-neutral storage keys is replaced by its storage's new domain.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerSupersededTests {
  static let formerKey = "Internal shared storage|"

  /// A device whose internal storage MTP used to key by description and volume.
  func device(
    _ serial: String, key: String = StorageKey.internal, formerKey: String? = Self.formerKey
  ) -> FakeDevice {
    let id = DeviceID(serial: serial)
    return FakeDevice(
      info: DeviceInfo(id: id, manufacturer: "NetAlly", model: "LinkRunner-100G"),
      storages: [
        StorageInfo(
          id: StorageID(device: id, key: key),
          description: "Internal shared storage", capacity: 1 << 30, free: 1 << 29,
          formerKey: formerKey)
      ])
  }

  func former(_ serial: String) -> String {
    DomainNaming.identifier(for: StorageID(device: DeviceID(serial: serial), key: Self.formerKey))
  }

  func current(_ serial: String) -> String {
    DomainNaming.identifier(
      for: StorageID(device: DeviceID(serial: serial), key: StorageKey.internal))
  }

  /// The old domain goes the way Remove Ferry removes one, keeping unsent changes; the new one
  /// is added.
  @Test func theOldDomainOfAnAttachedStorageIsRemoved() async throws {
    let unsent = URL(filePath: "/tmp/ferry-unsent")
    let manager = FakeDomainManager(existing: [former("S1")])
    await manager.preserve(former("S1"), at: unsent)
    let harness = try AgentHarness(devices: [device("S1")], manager: manager)
    defer { harness.finish() }

    let calls = await harness.barrier(after: 3)
    #expect(calls.contains(.remove(former("S1"))))
    #expect(
      calls.contains {
        if case .add(let spec) = $0 { spec.identifier == current("S1") } else { false }
      })
    #expect(
      await harness.service.handle(.list(domain: former("S1"), folder: .root), file: nil)
        == .failure(.deviceDisconnected))
  }

  /// Only an attached device's own storage retires a domain: another device's old domain, and
  /// one whose storage cannot be matched to its old key (not the primary, no former key), stay.
  @Test func unmatchedOldDomainsStay() async throws {
    let manager = FakeDomainManager(existing: [former("GONE"), former("S2")])
    let harness = try AgentHarness(
      devices: [device("S1"), device("S2", key: "Phone storage|", formerKey: nil)],
      manager: manager)
    defer { harness.finish() }

    let calls = await harness.barrier(after: 4)
    #expect(!calls.contains { if case .remove = $0 { true } else { false } })
  }

  /// Where the retired domain's unsent changes went reaches the app, as an eject's does.
  @Test func theKeptChangesOfARetiredDomainAreReported() async throws {
    let unsent = URL(filePath: "/tmp/ferry-unsent")
    let manager = FakeDomainManager(existing: [former("S1")])
    await manager.preserve(former("S1"), at: unsent)
    let harness = try AgentHarness(devices: [device("S1")], manager: manager)
    defer { harness.finish() }
    _ = await harness.barrier(after: 3)

    guard case .status(let report) = await harness.service.handle(.status, file: nil) else {
      Issue.record("expected a status")
      return
    }
    #expect(report.preservedChanges == [unsent])
  }

  /// A device served over ADB from the start retires its old MTP domain too: Android's primary
  /// storage was keyed by its description, which MTP sends as "Internal shared storage".
  @Test func aDeviceServedOverADBRetiresItsOldDomain() async throws {
    let manager = FakeDomainManager(existing: [former("S1")])
    let adb = FakeTransport(devices: [viaADB("S1")], method: .usbADB)
    let harness = try AgentHarness(manager: manager, adb: adb)
    defer { harness.finish() }

    let calls = await harness.barrier(after: 3)
    #expect(calls.contains(.remove(former("S1"))))
  }
}
