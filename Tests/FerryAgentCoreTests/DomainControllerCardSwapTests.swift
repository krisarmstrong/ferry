import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Another card, even one of the same vendor and size, never takes a card's Finder location.
extension DomainControllerCardTests {
  static func volumeDomain(_ volume: String) -> String {
    DomainNaming.identifier(for: StorageID(device: id, key: StorageKey.volume(volume)))
  }

  /// Serves the unit with card A over MTP, then over ADB, then lets it leave.
  func seenBothWaysThenGone(store: URL) async throws -> AgentHarness {
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [try await mtp()], store: store, adb: adbTransport)
    await until(harness) { $0.count >= 2 }
    await adbTransport.attach(try await adb())
    harness.tick()
    await served(harness, by: .usbADB)
    await until(harness) { calls in
      calls.contains {
        if case .add(let spec) = $0 { spec.identifier == Self.cardDomain } else { false }
      }
    }
    await adbTransport.detach(Self.id)
    await harness.transport.detach(Self.id)
    harness.tick()
    while await !harness.hub.devices().isEmpty, !Task.isCancelled { await Task.yield() }
    return harness
  }

  func reconnects(_ harness: AgentHarness, _ domain: String) async -> Int {
    await harness.manager.calls.filter { $0 == .reconnect(domain) }.count
  }

  /// Card A was seen both ways; card B, same vendor and size, comes back over MTP alone. B is
  /// served under the description, and A's location stays offline: a write meant for A is
  /// refused rather than sent to B.
  @Test func aSameSizeCardOverMTPNeverTakesAnotherCardsLocation() async throws {
    let harness = try await seenBothWaysThenGone(store: itemStore())
    defer { harness.finish() }
    let before = await reconnects(harness, Self.oldCardDomain)

    await harness.transport.attach(try await mtp(file: "/B.txt"))
    harness.tick()
    while await reconnects(harness, Self.oldCardDomain) == before, !Task.isCancelled {
      await Task.yield()
    }

    let aDomain = Self.cardDomain
    #expect(
      await harness.service.handle(.list(domain: aDomain, folder: .root), file: nil)
        == .failure(.deviceDisconnected))
    #expect(
      await harness.service.handle(
        .create(domain: aDomain, parent: .root, name: "for A", isFolder: true), file: nil)
        == .failure(.deviceDisconnected))
    #expect(await reconnects(harness, aDomain) == 0)
  }

  /// After a restart with a same-size card in, MTP alone never reconnects the other card's
  /// location.
  @Test func aRestartWithASameSizeCardKeepsTheCardsApart() async throws {
    let store = itemStore()
    try await seenBothWaysThenGone(store: store).finish(keepingStore: true)

    let restarted = try AgentHarness(
      devices: [try await mtp(file: "/B.txt")],
      existing: [Self.cardDomain, Self.oldCardDomain], store: store,
      adb: FakeTransport(devices: [], method: .usbADB))
    defer { restarted.finish() }
    await until(restarted) { $0.contains(.reconnect(Self.oldCardDomain)) }
    #expect(!(await restarted.manager.calls).contains(.reconnect(Self.cardDomain)))
  }
}
