import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Recovering from a replug, an agent restart and a removal.
extension DomainControllerTests {
  /// The owner's replug: the device comes back not sharing files (charge only), then the user
  /// turns on file transfer. The hub's one re-check must bring the domain back.
  @Test func replugNotSharingThenSharingReconnectsWithinOneRecheck() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)

    let replugged = await makeDevice("A", locked: true)
    await harness.transport.attach(replugged)
    harness.tick()
    await harness.clock.waitForSleeper()
    await replugged.setLocked(false)
    await harness.clock.advance(by: DeviceHub.recheckInterval)

    let domain = domainID(device)
    #expect(
      await harness.manager.waitForCalls(4).suffix(2) == [.reconnect(domain), .signal(domain)])
  }

  /// Right after an agent restart the extension may ask about a domain the controller has not
  /// adopted yet. "No such item" would make FileProvider delete the domain's items locally, so
  /// the request waits for adoption and the domain reads as disconnected, never as missing.
  @Test func requestBeforeAdoptionWaitsAndIsNeverNoSuchItem() async throws {
    let domain = domainID(await makeDevice("GONE"))
    let manager = FakeDomainManager(existing: [domain])
    await manager.holdExisting()
    let harness = try AgentHarness(manager: manager)
    defer { harness.finish() }

    let pending = Task { [service = harness.service] in
      await service.handle(.list(domain: domain, folder: .root), file: nil)
    }
    for _ in 0..<1_000 where await harness.controller.requestsAwaitingAdoption == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await harness.controller.requestsAwaitingAdoption == 1)
    await manager.releaseExisting()

    #expect(await pending.value == .failure(.deviceDisconnected))
    #expect(
      await harness.service.handle(.list(domain: "unknown", folder: .root), file: nil)
        == .failure(.deviceDisconnected))
  }

  /// Eject and Remove Ferry remove domains keeping unsent changes, and say where they went.
  @Test func removingDomainsReportsWhereUnsentChangesWent() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let saved = URL(filePath: "/tmp/Ferry unsent", directoryHint: .isDirectory)
    await harness.manager.preserve(domainID(device), at: saved)

    #expect(
      await harness.service.handle(.eject(device.info.id), file: nil)
        == .removed(preserved: [saved]))
    #expect(
      await harness.service.handle(.removeAllDomains, file: nil) == .removed(preserved: [saved]))
  }

  /// Domain identifiers carry no serial: FileProvider logs them, and they name folders.
  @Test func domainIdentifierIsAHashOfSerialAndStorage() throws {
    let storage = StorageID(device: DeviceID(serial: "0123456789abcdef"), key: internalKey)
    let identifier = DomainNaming.identifier(for: storage)

    #expect(identifier.count == 64)
    #expect(DomainNaming.isIdentifier(identifier))
    #expect(!identifier.contains("0123456789abcdef"))
    #expect(identifier == DomainNaming.identifier(for: storage))
    #expect(
      identifier
        != DomainNaming.identifier(
          for: StorageID(device: storage.device, key: cardKey)))
    #expect(!DomainNaming.isIdentifier("0123456789abcdef|Internal shared storage|65537"))
  }

  /// A domain from an earlier Ferry, named "<serial>|<key>", is removed (keeping unsent changes)
  /// with its item table, and the device's storage comes back under its new identifier.
  @Test func oldFormatDomainIsReplacedByItsHashedIdentifier() async throws {
    let device = await makeDevice("A")
    let old = "A|\(internalKey)"
    let store = itemStore()
    let oldTable = ItemTable.file(for: old, in: store)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data("{\"items\":{}}".utf8).write(to: oldTable)
    let harness = try AgentHarness(devices: [device], existing: [old], store: store)
    defer { harness.finish() }

    let added = FakeDomainManager.Call.add(
      DomainSpec(identifier: domainID(device), displayName: "Phone"))
    #expect(await harness.manager.waitForCalls(2) == [.remove(old), added])
    #expect(!FileManager.default.fileExists(atPath: oldTable.path))
  }

  /// Right after the agent starts, its status must wait for the first scan: an empty list then
  /// would show "No device connected" for a device that is plugged in.
  @Test func statusWaitsForTheFirstScan() async throws {
    let device = await makeDevice("A")
    await device.suspendNext(.storages)
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    await device.waitUntilSuspended(.storages)

    let status = Task { [service = harness.service] in
      await service.handle(.status, file: nil)
    }
    for _ in 0..<1_000 where await harness.hub.requestsAwaitingFirstScan == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    await device.resume(.storages)

    guard case .status(let report) = await status.value else {
      Issue.record("expected a status")
      return
    }
    #expect(report.devices.map(\.id) == [device.info.id])
  }

  /// An ejected unit stays listed (the transport keeps reporting it through its resets), but its
  /// domain does not come back with later scans.
  @Test func ejectedDomainIsNotAddedAgainByLaterScans() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    #expect(
      await harness.service.handle(.eject(device.info.id), file: nil) == .removed(preserved: []))
    harness.tick()

    let added = FakeDomainManager.Call.add(
      DomainSpec(identifier: domainID(device), displayName: "Phone"))
    let barrier = FakeDomainManager.Call.add(AgentHarness.barrierSpec)
    #expect(
      await harness.barrier(after: 2) == [added, .remove(domainID(device)), barrier])
  }
}
