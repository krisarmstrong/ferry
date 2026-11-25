import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// FileProvider keeps the identifiers the agent gave it. An item whose path did not change must
/// keep its identifier through relists, the device being unplugged and plugged back in (locked
/// or not), and agent restarts; otherwise every create into a folder FileProvider knows fails
/// as "no such item".
@Suite(.timeLimit(.minutes(1)))
struct AgentIdentityStabilityTests {
  static let folder = "/Download/ferry-e2e"
  static let file = "/Download/ferry-e2e/a.bin"

  /// A device holding `file`, with the domain's root, `/Download` and the folder listed for a
  /// client, as Finder would have them.
  func seeded(_ serial: String = "A") async throws -> FakeDevice {
    let device = await makeDevice(serial)
    try await device.seed(path(Self.file), in: storageID(device), contents: Data("a".utf8))
    return device
  }

  func list(_ harness: AgentHarness, _ domain: String, _ folder: ItemID = .root)
    async throws -> [ProviderEntry]
  {
    guard
      case .page(let entries, _) = await harness.service.handle(
        .list(domain: domain, folder: folder), file: nil)
    else { throw TransportError.io("listing failed") }
    return entries
  }

  /// Lists down to the folder and returns every identifier the table has for the seeded paths.
  func browse(_ harness: AgentHarness, _ domain: String) async throws -> [String: ItemID] {
    let top = try await list(harness, domain)
    let download = try #require(top.first { $0.item.path.name == "Download" })
    let inside = try await list(harness, domain, download.id)
    let folder = try #require(inside.first { $0.item.path.name == "ferry-e2e" })
    _ = try await list(harness, domain, folder.id)
    return try await ids(harness, domain)
  }

  func ids(_ harness: AgentHarness, _ domain: String) async throws -> [String: ItemID] {
    try await ids(in: try await harness.controller.items(of: domain))
  }

  func ids(in table: ItemTable) async throws -> [String: ItemID] {
    var ids: [String: ItemID] = [:]
    for name in ["/Download", Self.folder, Self.file] {
      ids[name] = await table.knows(try path(name)) ? await table.id(for: try path(name)) : nil
    }
    return ids
  }

  func create(_ harness: AgentHarness, _ domain: String, in folder: ItemID) async throws
    -> AgentResponse
  {
    await harness.service.handle(
      .create(domain: domain, parent: folder, name: "new.bin", isFolder: false),
      file: try harness.readable("new.bin", "new"))
  }

  @Test func relistingKeepsIdentifiers() async throws {
    let device = try await seeded()
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let before = try await browse(harness, domain)
    let anchor = try await harness.controller.items(of: domain).changeCount

    for _ in 0..<3 {
      #expect(await harness.service.handle(.refresh(device.info.id), file: nil) == .done)
    }

    #expect(try await ids(harness, domain) == before)
    let since = try await harness.controller.items(of: domain).changeCount
    #expect(since == anchor, "an unchanged relist recorded changes")
  }

  /// Unplugged and plugged back in: the reconnect relists every known folder, and a create into
  /// the folder FileProvider knows goes through.
  @Test func reconnectingKeepsIdentifiersAndCreatesStillWork() async throws {
    let device = try await seeded()
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let before = try await browse(harness, domain)

    await harness.transport.detach(device.info.id)
    harness.tick()
    await harness.manager.waitFor(.disconnect(domain))
    let replugged = try await seeded()
    await harness.transport.attach(replugged)
    harness.tick()
    await harness.manager.waitFor(.reconnect(domain))
    _ = await harness.manager.waitUntil { $0.madeReachable.contains(domain) }

    #expect(try await ids(harness, domain) == before)
    let folder = try #require(before[Self.folder])
    #expect(try await create(harness, domain, in: folder).isEntry)
  }

  /// Plugged back in locked, as a restarted phone is before its first unlock: the domain stays
  /// away until it is unlocked, and nothing the table knows is forgotten meanwhile.
  @Test func reconnectingLockedKeepsIdentifiers() async throws {
    let device = try await seeded()
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let before = try await browse(harness, domain)

    await harness.transport.detach(device.info.id)
    harness.tick()
    await harness.manager.waitFor(.disconnect(domain))
    let replugged = try await seeded()
    await replugged.setLocked(true)
    await harness.transport.attach(replugged)
    harness.tick()
    _ = await harness.barrier(after: await harness.manager.calls.count)
    #expect(!(await harness.manager.calls.contains(.reconnect(domain))))
    // The domain is disconnected, so its table is read as a restart would load it.
    #expect(try await ids(in: ItemTable(domain: domain, store: harness.store)) == before)

    await replugged.setLocked(false)
    _ = await harness.service.handle(.recheck(device.info.id), file: nil)
    await harness.manager.waitFor(.reconnect(domain))
    _ = await harness.manager.waitUntil { $0.madeReachable.contains(domain) }

    #expect(try await ids(harness, domain) == before)
    let folder = try #require(before[Self.folder])
    #expect(try await create(harness, domain, in: folder).isEntry)
  }

  /// Stopped and started again: the table reloads from its snapshot and journal, folded or not.
  @Test(arguments: [false, true])
  func restartingKeepsIdentifiers(folded: Bool) async throws {
    let device = try await seeded()
    let store = itemStore()
    let domain = domainID(device)
    let first = try AgentHarness(devices: [device], store: store)
    _ = await first.manager.waitForCalls(1)
    let before = try await browse(first, domain)
    if folded {
      // Enough relists of a changing folder that the journal outgrows the snapshot and is
      // folded into a new one.
      let table = try await first.controller.items(of: domain)
      let snapshots = await table.work.snapshots
      var round = 0
      while await table.work.snapshots == snapshots, round < 200 {
        round += 1
        try await device.seed(
          path("/Download/churn-\(round).txt"), in: storageID(device), contents: Data())
        #expect(await first.service.handle(.refresh(device.info.id), file: nil) == .done)
      }
    }
    first.finish(keepingStore: true)

    let again = try await seeded()
    let restarted = try AgentHarness(devices: [again], existing: [domain], store: store)
    defer { restarted.finish() }
    await restarted.manager.waitFor(.reconnect(domain))

    #expect(try await ids(restarted, domain) == before)
    let folder = try #require(before[Self.folder])
    #expect(try await create(restarted, domain, in: folder).isEntry)
  }

  /// FileProvider names a folder the table does not know as the place for a new item: an
  /// earlier agent lost identifiers FileProvider still holds. The domain is reimported, once.
  @Test func aCreateIntoAFolderTheTableLostReimportsTheDomainOnce() async throws {
    let device = try await seeded()
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let lost = ItemID.random()

    #expect(try await create(harness, domain, in: lost) == .failure(.unknownItem))
    #expect(try await create(harness, domain, in: lost) == .failure(.unknownItem))
    let moved = await harness.service.handle(
      .move(domain: domain, id: try await harness.id(path(Self.file), in: domain), toFolder: lost),
      file: nil)
    #expect(moved == .failure(.unknownItem))

    #expect(await harness.manager.calls.filter { $0 == .reimport(domain) }.count == 1)
  }

  /// An unknown item is no sign of lost identifiers on its own: FileProvider may ask about one
  /// the device deleted.
  @Test func anUnknownItemAloneReimportsNothing() async throws {
    let device = try await seeded()
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)

    #expect(
      await harness.service.handle(.item(domain: domain, id: ItemID.random()), file: nil)
        == .failure(.unknownItem))
    #expect(
      await harness.service.handle(
        .rename(domain: domain, id: ItemID.random(), to: "b"), file: nil)
        == .failure(.unknownItem))

    #expect(!(await harness.manager.calls.contains(.reimport(domain))))
  }
}
