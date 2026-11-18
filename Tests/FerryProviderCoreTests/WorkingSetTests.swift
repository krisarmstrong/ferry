import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// FileProvider's working set: every item the agent knows, then the changes after an anchor.
struct WorkingSetTests {
  @Test func workingSetChangesComeFromTheAgent() async throws {
    let agent = FakeAgent()
    let backend = ProviderBackend(domain: domain, client: agent)
    let changed = ProviderEntry(id: .random(), parent: .root, item: try file("/a.txt"))
    let gone = ItemID.random()
    await agent.set(changes: [changed], deleted: [gone])

    let anchor = try await backend.currentAnchor()
    let changes = try await backend.changes(since: anchor)

    #expect(anchor.rawValue == Data([1]))
    #expect(changes.anchor.rawValue == Data([2]))
    #expect(changes.updated.map(\.entry) == [changed])
    #expect(changes.deleted == [NSFileProviderItemIdentifier(gone)])
    await #expect(throws: NSFileProviderError(.syncAnchorExpired)) {
      try await backend.changes(since: NSFileProviderSyncAnchor(rawValue: Data([7])))
    }
  }

  @Test func workingSetPagesThroughEveryItem() async throws {
    let agent = FakeAgent([
      try folder("/DCIM"), try file("/DCIM/a.jpg"), try file("/b.txt"), try file("/c.txt"),
      try folder("/Music"),
    ])
    let backend = ProviderBackend(domain: domain, client: agent)

    var seen: [NSFileProviderItemIdentifier] = []
    var page: NSFileProviderPage? = NSFileProviderPage(
      rawValue: NSFileProviderPage.initialPageSortedByName as Data)
    var pages = 0
    while let current = page {
      let result = try await backend.workingSet(from: current)
      seen += result.items.map(\.itemIdentifier)
      page = result.next
      pages += 1
    }

    var expected: [NSFileProviderItemIdentifier] = []
    for name in ["/DCIM", "/DCIM/a.jpg", "/b.txt", "/c.txt", "/Music"] {
      expected.append(try await agent.identifier(try path(name)))
    }
    #expect(Set(seen) == Set(expected))
    #expect(seen.count == expected.count)
    #expect(pages == 3)
    #expect(!seen.contains(.rootContainer))
    await #expect(throws: NSFileProviderError(.pageExpired)) {
      try await backend.workingSet(from: NSFileProviderPage(rawValue: Data([1, 2, 3])))
    }
  }

  @Test func emptyDomainHasEmptyWorkingSet() async throws {
    let backend = ProviderBackend(domain: domain, client: FakeAgent())
    let first = try await backend.workingSet(
      from: NSFileProviderPage(rawValue: NSFileProviderPage.initialPageSortedByDate as Data))
    #expect(first.items.isEmpty)
    #expect(first.next == nil)
  }
}
