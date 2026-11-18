import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A card match is applied only when it is certain: another card, or a USB drive, never takes a
/// card's Finder location.
extension DomainControllerCardTests {
  static func volumeDomain(_ volume: String) -> String {
    DomainNaming.identifier(for: StorageID(device: id, key: StorageKey.volume(volume)))
  }

  /// How many times the domain under the card's description was added.
  func descriptionAdds(_ harness: AgentHarness) async -> Int {
    await harness.manager.calls.filter {
      if case .add(let spec) = $0 { return spec.identifier == Self.oldCardDomain }
      return false
    }.count
  }

  /// Matches card A over MTP and ADB, then returns the harness serving it over MTP again.
  func matchedCardA(store: URL) async throws -> (AgentHarness, FakeTransport) {
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(
      devices: [try await mtp()], store: store, adb: adbTransport)
    await until(harness) { $0.count >= 2 }
    await adbTransport.attach(try await adb())
    harness.tick()
    await served(harness, by: .usbADB)
    await until(harness) { $0.contains(.remove(Self.oldCardDomain)) }
    return (harness, adbTransport)
  }

  /// Card A was matched; card B, same vendor and description, is put in and the unit comes
  /// back over MTP. B is served in a location of its own, and a write meant for A's location is
  /// refused rather than sent to B.
  @Test func anotherCardNeverTakesTheMatchedCardsLocation() async throws {
    let store = itemStore()
    let (first, adbTransport) = try await matchedCardA(store: store)
    await adbTransport.detach(Self.id)
    await first.transport.detach(Self.id)
    first.tick()
    while await !first.hub.devices().isEmpty, !Task.isCancelled { await Task.yield() }

    let added = await descriptionAdds(first)
    await first.transport.attach(try await mtp(capacity: Self.cardB.capacity, file: "/B.txt"))
    first.tick()
    while await descriptionAdds(first) == added, !Task.isCancelled { await Task.yield() }

    let aDomain = Self.volumeDomain(Self.cardA.volume)
    let aRoot = await first.service.handle(.list(domain: aDomain, folder: .root), file: nil)
    #expect(aRoot == .failure(.deviceDisconnected))
    let write = await first.service.handle(
      .create(domain: aDomain, parent: .root, name: "for A", isFolder: true), file: nil)
    #expect(write == .failure(.deviceDisconnected))
    first.finish()
  }

  /// The card was last seen over MTP; the unit comes back over ADB with only a USB drive in.
  /// Nothing is matched: the drive gets its own location.
  @Test func aUSBDriveIsNeverMatchedToACard() async throws {
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [try await mtp()], adb: adbTransport)
    defer { harness.finish() }
    await until(harness) { $0.count >= 2 }

    await harness.transport.detach(Self.id)
    harness.tick()
    while await !harness.hub.devices().isEmpty, !Task.isCancelled { await Task.yield() }
    // The drive has the card's size, so only the detach keeps the two apart.
    await adbTransport.attach(try await adb(volume: "C0DE-0001"))
    harness.tick()
    await served(harness, by: .usbADB)
    await until(harness) { calls in
      calls.contains {
        if case .add(let spec) = $0 {
          spec.identifier == Self.volumeDomain("C0DE-0001")
        } else {
          false
        }
      }
    }
    #expect(!(await harness.manager.calls).contains(.remove(Self.oldCardDomain)))
    #expect(await harness.controller.aliases == StorageAliases())
  }

  /// After a restart with card B in, MTP alone serves B in a location of its own, not in A's.
  @Test func aRestartWithAnotherCardKeepsTheCardsApart() async throws {
    let store = itemStore()
    let (first, _) = try await matchedCardA(store: store)
    first.finish(keepingStore: true)

    let restarted = try AgentHarness(
      devices: [try await mtp(capacity: Self.cardB.capacity, file: "/B.txt")],
      existing: [Self.volumeDomain(Self.cardA.volume)], store: store,
      adb: FakeTransport(devices: [], method: .usbADB))
    defer { restarted.finish() }
    await until(restarted) {
      $0.contains {
        if case .add(let spec) = $0 { spec.identifier == Self.oldCardDomain } else { false }
      }
    }
    #expect(
      !(await restarted.manager.calls).contains(.reconnect(Self.volumeDomain(Self.cardA.volume))))
  }

  /// Card A was matched, and the unit is now seen both ways with card B: B is matched in A's
  /// place, and A's location is retired, its unsent changes kept.
  @Test func aNewCardSeenBothWaysReplacesTheMatch() async throws {
    let store = itemStore()
    let (first, adbTransport) = try await matchedCardA(store: store)
    defer { first.finish() }
    await adbTransport.detach(Self.id)
    await first.transport.detach(Self.id)
    first.tick()
    while await !first.hub.devices().isEmpty, !Task.isCancelled { await Task.yield() }

    await first.transport.attach(try await mtp(capacity: Self.cardB.capacity, file: "/B.txt"))
    first.tick()
    await served(first, by: .usbFileTransfer)
    await adbTransport.attach(
      try await adb(volume: Self.cardB.volume, capacity: Self.cardB.capacity, file: "/B.txt"))
    first.tick()
    await served(first, by: .usbADB)
    await until(first) { $0.contains(.remove(Self.volumeDomain(Self.cardA.volume))) }
    #expect(
      await first.controller.aliases.identity(
        of: StorageInfo(
          id: Self.mtpCard, description: "SD card", capacity: Self.cardB.capacity, free: 0))
        == StorageID(device: Self.id, key: StorageKey.volume(Self.cardB.volume)))
  }
}
