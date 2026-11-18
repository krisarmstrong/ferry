import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Item identifiers as the agent hands them out: stable while the item lives, across restarts and
/// unplugging, and gone once the item or its domain is.
@Suite(.timeLimit(.minutes(1)))
struct AgentIdentityTests {
  @Test func unknownIDIsNotFound() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/a.txt"), in: storageID(device), contents: Data("a".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let unknown = ItemID.random()
    let service = harness.service

    for request: AgentRequest in [
      .item(domain: domain, id: unknown), .list(domain: domain, folder: unknown),
      .create(domain: domain, parent: unknown, name: "b", isFolder: true),
      .rename(domain: domain, id: unknown, to: "b"),
      .move(
        domain: domain, id: try await harness.id(path("/a.txt"), in: domain), toFolder: unknown),
    ] {
      #expect(await service.handle(request, file: nil) == .failure(.unknownItem), "\(request)")
    }
    // FileProvider's contract: deleting an item that is already gone succeeds.
    #expect(
      await service.handle(
        .delete(domain: domain, id: unknown, base: nil, recursive: false), file: nil) == .done)
    let (_, handle) = try harness.writable("out", "")
    #expect(
      await service.handle(.fetch(domain: domain, id: unknown), file: handle)
        == .failure(.unknownItem))
    #expect(await device.allPaths(in: storageID(device)) == [try path("/a.txt")])
  }

  @Test func rootCannotBeChanged() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let refused = AgentResponse.failure(.unsupported("changing the storage root"))

    #expect(
      await harness.service.handle(
        .delete(domain: domain, id: .root, base: nil, recursive: false), file: nil) == refused)
    #expect(
      await harness.service.handle(.rename(domain: domain, id: .root, to: "x"), file: nil)
        == refused)
  }

  @Test func listingGivesEachChildItsIdentifier() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/Docs/a.txt"), in: storageID(device), contents: Data("a".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let service = harness.service

    guard
      case .entries(let top) = await service.handle(.list(domain: domain, folder: .root), file: nil),
      let docs = top.first
    else {
      Issue.record("expected a listing")
      return
    }
    #expect(docs.parent == .root)
    #expect(docs.item.path == (try path("/Docs")))
    guard
      case .entries(let inner) = await service.handle(
        .list(domain: domain, folder: docs.id), file: nil)
    else {
      Issue.record("expected a listing")
      return
    }
    #expect(inner.map(\.parent) == [docs.id])
    #expect(
      await service.handle(.item(domain: domain, id: inner[0].id), file: nil) == .entry(inner[0]))
    #expect(
      await service.handle(.item(domain: domain, id: .root), file: nil)
        == .entry(
          ProviderEntry(
            id: .root, parent: .root,
            item: RemoteItem(path: .root, kind: .folder, size: 0, modified: .distantPast))))
  }

  /// A listing of the old folder that read the device before a rename must not drop the renamed
  /// item's identifier when it lands after the rename.
  @Test func renameDuringListingKeepsIdentifier() async throws {
    let device = await makeDevice("A")
    let old = try path("/Docs/old.txt")
    try await device.seed(old, in: storageID(device), contents: Data("a".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let (docs, id) = (
      try await harness.id(path("/Docs"), in: domain), try await harness.id(old, in: domain)
    )
    let service = harness.service

    await device.suspendNext(.list)
    let listing = Task { await service.handle(.list(domain: domain, folder: docs), file: nil) }
    await device.waitUntilSuspended(.list)
    let rename = Task {
      await service.handle(.rename(domain: domain, id: id, to: "new.txt"), file: nil)
    }
    let gate = try await harness.controller.items(of: domain).gate
    while await gate.waiting == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    await device.resume(.list)

    _ = await listing.value
    guard case .entry(let renamed) = await rename.value else {
      Issue.record("rename failed")
      return
    }
    #expect(renamed.id == id)
    guard case .entry(let current) = await service.handle(.item(domain: domain, id: id), file: nil)
    else {
      Issue.record("the renamed item lost its identifier")
      return
    }
    #expect(current.item.path == (try path("/Docs/new.txt")))
  }

  @Test func restartKeepsIdentifiers() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/a.txt"), in: storageID(device), contents: Data("a".utf8))
    let store = itemStore()
    let domain = domainID(device)
    let first = try AgentHarness(devices: [device], store: store)
    _ = await first.manager.waitForCalls(1)
    let id = try await first.id(path("/a.txt"), in: domain)
    first.finish(keepingStore: true)

    let again = await makeDevice("A")
    try await again.seed(path("/a.txt"), in: storageID(again), contents: Data("a".utf8))
    let restarted = try AgentHarness(devices: [again], existing: [domain], store: store)
    defer { restarted.finish() }
    _ = await restarted.manager.waitForCalls(2)

    guard
      case .entry(let entry) = await restarted.service.handle(
        .item(domain: domain, id: id), file: nil)
    else {
      Issue.record("the identifier did not survive the restart")
      return
    }
    #expect(entry.item.path == (try path("/a.txt")))
  }

  @Test func unplugKeepsIdentifiersAndEjectForgetsThem() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/a.txt"), in: storageID(device), contents: Data("a".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let domain = domainID(device)
    let id = try await harness.id(path("/a.txt"), in: domain)

    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)
    let replugged = await makeDevice("A")
    try await replugged.seed(path("/a.txt"), in: storageID(replugged), contents: Data("a".utf8))
    await harness.transport.attach(replugged)
    harness.tick()
    _ = await harness.manager.waitForCalls(3)
    #expect(try await harness.id(path("/a.txt"), in: domain) == id)

    #expect(
      await harness.service.handle(.eject(device.info.id), file: nil) == .removed(preserved: []))
    #expect(
      !FileManager.default.fileExists(
        atPath: ItemTable.file(for: domain, in: harness.store).path))
    #expect(await ItemTable(domain: domain, store: harness.store).path(for: id) == nil)
  }

  @Test func removeAllForgetsEveryTable() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/a.txt"), in: storageID(device), contents: Data("a".utf8))
    let store = itemStore()
    // A table left by a domain this agent never loaded.
    _ = await ItemTable(domain: "GONE|Internal|vol0", store: store).id(for: try path("/x"))
    let harness = try AgentHarness(devices: [device], store: store)
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    _ = try await harness.id(path("/a.txt"), in: domainID(device))

    #expect(await harness.service.handle(.removeAllDomains, file: nil) == .removed(preserved: []))

    let left = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
    #expect(left.isEmpty)
  }
}
