import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A domain with one ready device, its service, and the change log as a client reads it.
private struct Domain {
  let harness: AgentHarness
  let device: FakeDevice
  let name: String

  init(seeding files: [String]) async throws {
    device = await makeDevice("A")
    for file in files {
      try await device.seed(path(file), in: storageID(device), contents: Data("a".utf8))
    }
    harness = try AgentHarness(devices: [device])
    name = domainID(device)
    _ = await harness.manager.waitForCalls(1)
  }

  var storage: StorageID { storageID(device) }

  func send(_ request: AgentRequest) async -> AgentResponse {
    await harness.service.handle(request, file: nil)
  }

  func list(_ folder: ItemID = .root) async throws -> [ProviderEntry] {
    guard case .entries(let entries) = await send(.list(domain: name, folder: folder)) else {
      throw TransportError.io("listing failed")
    }
    return entries
  }

  func entry(_ request: AgentRequest) async throws -> ProviderEntry {
    guard case .entry(let entry) = await send(request) else {
      throw TransportError.io("\(request) failed")
    }
    return entry
  }

  func changes(since anchor: Data?) async throws -> ChangeLog.Since {
    guard
      case .changes(let next, let updated, let deleted, false) = await send(
        .changes(domain: name, since: anchor))
    else { throw TransportError.io("no changes") }
    return ChangeLog.Since(anchor: next, updated: updated, deleted: deleted, expired: false)
  }

  func signalCount() async -> Int {
    await harness.manager.calls.count { $0 == .signal(name) }
  }
}

/// The change log behind FileProvider's working set, and identity across changes made on the
/// phone.
@Suite(.timeLimit(.minutes(1)))
struct AgentChangeTests {
  @Test func sinceNilReturnsAnchorOnly() async throws {
    let domain = try await Domain(seeding: ["/a.txt"])
    defer { domain.harness.finish() }
    _ = try await domain.list()

    let current = try await domain.changes(since: nil)

    #expect(current.updated.isEmpty && current.deleted.isEmpty)
    #expect(try await domain.changes(since: current.anchor).anchor == current.anchor)
  }

  @Test func listingRecordsAddedChangedAndVanished() async throws {
    let domain = try await Domain(seeding: ["/a.txt", "/b.txt", "/same.txt"])
    defer { domain.harness.finish() }
    let before = Dictionary(
      uniqueKeysWithValues: try await domain.list().map { ($0.item.path.name ?? "", $0.id) })
    let anchor = try await domain.changes(since: nil).anchor
    let signals = await domain.signalCount()
    // Changed on the phone, outside Ferry.
    try await domain.device.seed(path("/a.txt"), in: domain.storage, contents: Data("longer".utf8))
    try await domain.device.seed(path("/c.txt"), in: domain.storage, contents: Data("c".utf8))
    try await domain.device.delete(path("/b.txt"), in: domain.storage)

    let after = try await domain.list()
    let changes = try await domain.changes(since: anchor)

    #expect(after.first { $0.item.path.name == "a.txt" }?.id == before["a.txt"])
    #expect(Set(changes.updated.compactMap(\.item.path.name)) == ["a.txt", "c.txt"])
    #expect(changes.deleted == [try #require(before["b.txt"])])
    #expect(await domain.signalCount() == signals + 1)
    // The same listing again changes nothing and signals nothing.
    _ = try await domain.list()
    #expect(try await domain.changes(since: changes.anchor).updated.isEmpty)
    #expect(await domain.signalCount() == signals + 1)
  }

  @Test func kindChangeOnThePhoneIsANewItem() async throws {
    let domain = try await Domain(seeding: ["/x"])
    defer { domain.harness.finish() }
    let old = try #require(try await domain.list().first)
    try await domain.device.delete(path("/x"), in: domain.storage)
    _ = try await domain.device.makeFolder(path("/x"), in: domain.storage)

    #expect(await domain.send(.item(domain: domain.name, id: old.id)) == .failure(.unknownItem))
    let now = try #require(try await domain.list().first)

    #expect(now.id != old.id)
    #expect(now.item.kind == .folder)
  }

  @Test func createNeverReusesAStaleIdentifier() async throws {
    let domain = try await Domain(seeding: ["/x.txt"])
    defer { domain.harness.finish() }
    let stale = try #require(try await domain.list().first)
    try await domain.device.delete(path("/x.txt"), in: domain.storage)
    let anchor = try await domain.changes(since: nil).anchor

    let made = try await domain.entry(
      .create(domain: domain.name, parent: .root, name: "x.txt", isFolder: true))

    #expect(made.id != stale.id)
    let changes = try await domain.changes(since: anchor)
    #expect(changes.updated == [made])
    #expect(changes.deleted == [stale.id])
  }

  @Test func renamedFolderKeepsItsChildrensIdentifiers() async throws {
    let domain = try await Domain(seeding: ["/Docs/a.txt"])
    defer { domain.harness.finish() }
    let docs = try #require(try await domain.list().first)
    let child = try #require(try await domain.list(docs.id).first)

    let renamed = try await domain.entry(.rename(domain: domain.name, id: docs.id, to: "Papers"))
    let moved = try await domain.entry(.item(domain: domain.name, id: child.id))

    #expect(renamed.id == docs.id)
    #expect(moved.item.path == (try path("/Papers/a.txt")))
    #expect(moved.parent == docs.id)
  }
}
