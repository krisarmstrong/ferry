import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let tableDomain = "SER0000AAAA|Internal|vol0"

private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

private func file(_ string: String, size: UInt64 = 1) throws -> RemoteItem {
  RemoteItem(path: try path(string), kind: .file, size: size, modified: stamp)
}

private func folder(_ string: String) throws -> RemoteItem {
  RemoteItem(path: try path(string), kind: .folder, size: 0, modified: stamp)
}

/// A new, empty store folder for one test.
private func store() -> URL {
  TestScratch.root.appending(
    path: "ferry-items-\(UUID().uuidString)", directoryHint: .isDirectory)
}

struct ItemTableTests {
  @Test func rootIsFixed() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    #expect(await table.id(for: .root) == .root)
    #expect(await table.path(for: .root) == .root)
  }

  @Test func idsAreStableAcrossRenameAndMove() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let id = await table.id(for: try path("/Docs/a.txt"))
    #expect(await table.id(for: try path("/Docs/a.txt")) == id)

    await table.moved(try path("/Docs/a.txt"), to: try path("/Docs/b.txt"))
    #expect(await table.path(for: id) == (try path("/Docs/b.txt")))
    #expect(await table.id(for: try path("/Docs/b.txt")) == id)

    await table.moved(try path("/Docs/b.txt"), to: try path("/Other/b.txt"))
    #expect(await table.path(for: id) == (try path("/Other/b.txt")))
    // The old path is free: something new there is a new item.
    #expect(await table.id(for: try path("/Docs/a.txt")) != id)
  }

  @Test func subtreeMovesKeepIDs() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let folder = await table.id(for: try path("/A"))
    let inner = await table.id(for: try path("/A/B"))
    let leaf = await table.id(for: try path("/A/B/c.txt"))
    let sibling = await table.id(for: try path("/AB"))
    // A stale entry where the folder lands is replaced by the folder's own.
    let stale = await table.id(for: try path("/Z/B"))

    await table.moved(try path("/A"), to: try path("/Z"))

    #expect(await table.path(for: folder) == (try path("/Z")))
    #expect(await table.path(for: inner) == (try path("/Z/B")))
    #expect(await table.path(for: leaf) == (try path("/Z/B/c.txt")))
    #expect(await table.path(for: sibling) == (try path("/AB")))
    #expect(await table.path(for: stale) == nil)
    #expect(await table.id(for: try path("/Z/B")) == inner)
  }

  @Test func deletePrunes() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let folder = await table.id(for: try path("/A"))
    let leaf = await table.id(for: try path("/A/b.txt"))
    let sibling = await table.id(for: try path("/AB"))

    await table.removed(try path("/A"))

    #expect(await table.path(for: folder) == nil)
    #expect(await table.path(for: leaf) == nil)
    #expect(await table.path(for: sibling) == (try path("/AB")))
  }

  @Test func listingPrunesVanishedChildren() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let kept = await table.id(for: try path("/D/a"))
    let gone = await table.id(for: try path("/D/b"))
    let goneChild = await table.id(for: try path("/D/b/x"))
    let elsewhere = await table.id(for: try path("/E/b"))

    let ids = await table.listed(try path("/D"), children: [try file("/D/a"), try file("/D/c")])
      .map(\.id)

    try #require(ids.count == 2)
    #expect(ids[0] == kept)
    #expect(await table.path(for: ids[1]) == (try path("/D/c")))
    #expect(await table.path(for: gone) == nil)
    #expect(await table.path(for: goneChild) == nil)
    #expect(await table.path(for: elsewhere) == (try path("/E/b")))
  }

  @Test func tablePersistsAcrossReload() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = ItemTable(domain: tableDomain, store: folder)
    let id = await first.id(for: try path("/Docs/a.txt"))
    await first.moved(try path("/Docs/a.txt"), to: try path("/Docs/b.txt"))

    let reloaded = ItemTable(domain: tableDomain, store: folder)
    #expect(await reloaded.path(for: id) == (try path("/Docs/b.txt")))
    #expect(await reloaded.id(for: try path("/Docs/b.txt")) == id)
    // Each domain has a table of its own.
    #expect(await ItemTable(domain: "other", store: folder).path(for: id) == nil)

    await reloaded.discard()
    // A discarded table writes nothing more, so the domain's next table starts empty.
    _ = await reloaded.id(for: try path("/Docs/c.txt"))
    #expect(
      !FileManager.default.fileExists(atPath: ItemTable.file(for: tableDomain, in: folder).path))
    #expect(await ItemTable(domain: tableDomain, store: folder).path(for: id) == nil)
  }

  @Test(arguments: [Data("{not json".utf8), Data(#"{"items":{"root":"/a"}}"#.utf8)])
  func unreadableTableStartsEmpty(_ contents: Data) async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try contents.write(to: ItemTable.file(for: tableDomain, in: folder))

    let table = ItemTable(domain: tableDomain, store: folder)
    let id = await table.id(for: try path("/a"))
    #expect(id != .root)
    #expect(await ItemTable(domain: tableDomain, store: folder).path(for: id) == (try path("/a")))
  }

  @Test func duplicatePathsStartEmpty() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let (one, two) = (UUID().uuidString, UUID().uuidString)
    let json = #"{"items":{"\#(one)":"/a","\#(two)":"/a"}}"#
    try Data(json.utf8).write(to: ItemTable.file(for: tableDomain, in: folder))

    let table = ItemTable(domain: tableDomain, store: folder)
    #expect(await table.path(for: try #require(ItemID(rawValue: one))) == nil)
    #expect(await table.path(for: try #require(ItemID(rawValue: two))) == nil)
  }

  @Test func idsContainNoNames() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let table = ItemTable(domain: tableDomain, store: folder)
    let names = ["Secret Plans", "résumé.pdf", "IMG_0001.jpg"]
    var ids: [ItemID] = []
    for name in names {
      ids.append(await table.id(for: try RemotePath.root.appending(name)))
    }
    ids += await table.listed(.root, children: try names.map { try file("/" + $0) }).map(\.id)

    for id in ids {
      #expect(UUID(uuidString: id.rawValue)?.uuidString == id.rawValue)
      for name in names {
        #expect(!id.rawValue.contains(name))
      }
    }
    #expect(Set(ids).count == names.count)
    // Nor does the table's file name carry the device serial.
    let tableFile = ItemTable.file(for: tableDomain, in: folder).lastPathComponent
    #expect(!tableFile.contains("SER0000AAAA"))
    #expect(ItemID(rawValue: "/Secret Plans") == nil)
  }

  @Test func discardAllRemovesTablesNeverLoaded() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let id = await ItemTable(domain: tableDomain, store: folder).id(for: try path("/a"))

    ItemTable.discardAll(in: folder)

    #expect(await ItemTable(domain: tableDomain, store: folder).path(for: id) == nil)
  }

  @Test func kindChangeGetsNewIdentifier() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let old = try #require(await table.listed(.root, children: [try file("/x")]).first)
    let inner = await table.id(for: try path("/x/y"))

    let replaced = try #require(await table.listed(.root, children: [try folder("/x")]).first)
    #expect(replaced.id != old.id)
    #expect(await table.path(for: old.id) == nil)
    #expect(await table.path(for: inner) == nil)

    // A file whose contents changed is still the same file.
    let rewritten = await table.observed(try folder("/x"))
    #expect(rewritten.id == replaced.id)
    let kept = try #require(await table.listed(.root, children: [try file("/f", size: 1)]).first)
    #expect(await table.observed(try file("/f", size: 2)).id == kept.id)
  }

  @Test func createdNeverTakesAStaleIdentifier() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let stale = try #require(await table.listed(.root, children: [try file("/x")]).first)

    let made = await table.created(try file("/x"))

    #expect(made.id != stale.id)
    #expect(await table.path(for: stale.id) == nil)
    let since = await table.changes(since: nil).anchor
    _ = await table.created(try folder("/y"))
    let changes = await table.changes(since: since)
    #expect(changes.updated.map(\.item.path) == [try path("/y")])
  }

  @Test func onlyChangesAreSaved() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let table = ItemTable(domain: tableDomain, store: folder)
    let children = [try file("/a"), try file("/b")]
    _ = await table.listed(.root, children: children)
    let saved = [
      ItemTable.file(for: tableDomain, in: folder), ItemTable.journal(for: tableDomain, in: folder),
    ]
    for file in saved { try? FileManager.default.removeItem(at: file) }
    let written = { saved.contains { FileManager.default.fileExists(atPath: $0.path) } }

    // Nothing new: the same listing, a move to where the item is, an unknown removal.
    _ = await table.listed(.root, children: children)
    await table.moved(try path("/a"), to: try path("/a"))
    await table.removed(try path("/zzz"))
    _ = await table.id(for: try path("/a"))
    #expect(!written())

    _ = await table.listed(.root, children: [try file("/a")])
    #expect(written())
  }

  @Test func workingSetPagesReportedItemsOnly() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let listed = await table.listed(
      .root, children: [try file("/a"), try file("/b"), try folder("/C")])
    _ = await table.id(for: try path("/known-only-by-path"))

    let first = await table.workingSet(after: nil, size: 2)
    let cursor: ItemID = try #require(first.next)
    let second = await table.workingSet(after: cursor, size: 2)

    #expect(first.entries.count == 2)
    #expect(second.next == nil)
    #expect(Set((first.entries + second.entries).map(\.id)) == Set(listed.map(\.id)))
    #expect(
      first.entries + second.entries
        == (first.entries + second.entries).sorted {
          $0.id.rawValue < $1.id.rawValue
        })
    #expect(await table.workingSet(after: second.entries.last?.id, size: 2).entries.isEmpty)
  }

  /// An item deleted after it was served must not shift an unchanged one out of the next page:
  /// FileProvider would take the missing item as deleted, and no change would ever restore it.
  @Test func deleteBetweenPagesSkipsNothing() async throws {
    let table = ItemTable(domain: tableDomain, store: store())
    let all = await table.listed(.root, children: try (0..<6).map { try file("/f\($0)") })

    let first = await table.workingSet(after: nil, size: 2)
    let served = try #require(first.entries.first)
    await table.removed(served.item.path)
    var delivered = first.entries.map(\.id)
    var next = first.next
    while let cursor = next {
      let page = await table.workingSet(after: cursor, size: 2)
      delivered += page.entries.map(\.id)
      next = page.next
    }

    #expect(Set(all.map(\.id)).subtracting(delivered).isEmpty)
  }
}

/// The journal a save appends to, and the snapshot it is folded into.
struct ItemTableJournalTests {
  /// A save appends the changed records to the journal; the journal is folded into the snapshot
  /// once it outgrows it, and a reload sees every change either way.
  @Test func changesAreJournalledThenFolded() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let table = ItemTable(domain: tableDomain, store: folder)
    let snapshot = ItemTable.file(for: tableDomain, in: folder)
    let journal = ItemTable.journal(for: tableDomain, in: folder)
    let first = await table.observed(try file("/first"))
    #expect(FileManager.default.fileExists(atPath: snapshot.path))
    let second = await table.observed(try file("/second"))
    #expect(FileManager.default.fileExists(atPath: journal.path))
    await table.removed(try path("/first"))

    var reloaded = ItemTable(domain: tableDomain, store: folder)
    #expect(await reloaded.path(for: first.id) == nil)
    #expect(await reloaded.path(for: second.id) == (try path("/second")))

    var last = second
    var size = UInt64(1)
    while FileManager.default.fileExists(atPath: journal.path) {
      size += 1
      last = await table.observed(try file("/second", size: size))
      try #require(size < 10_000, "the journal was never folded in")
    }
    reloaded = ItemTable(domain: tableDomain, store: folder)
    #expect(await reloaded.path(for: last.id) == (try path("/second")))
    #expect(await reloaded.reportedAsIs(try file("/second", size: size)))
  }

  /// The agent stopped while appending: the torn batch is dropped, the ones before it kept, and
  /// the next save writes a snapshot rather than appending after the torn line.
  @Test func aTornJournalBatchIsDropped() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let table = ItemTable(domain: tableDomain, store: folder)
    let kept = await table.observed(try file("/a"))
    let journalled = await table.observed(try file("/b"))
    let journal = ItemTable.journal(for: tableDomain, in: folder)
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"items":{"#.utf8))
    try handle.close()

    let reloaded = ItemTable(domain: tableDomain, store: folder)
    #expect(await reloaded.path(for: kept.id) == (try path("/a")))
    #expect(await reloaded.path(for: journalled.id) == (try path("/b")))
    let after = await reloaded.observed(try file("/c"))
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    #expect(await ItemTable(domain: tableDomain, store: folder).path(for: after.id) != nil)
  }

  @Test func discardRemovesTheJournal() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let table = ItemTable(domain: tableDomain, store: folder)
    _ = await table.observed(try file("/a"))
    _ = await table.observed(try file("/b"))
    let journal = ItemTable.journal(for: tableDomain, in: folder)
    #expect(FileManager.default.fileExists(atPath: journal.path))
    ItemTable.discardAll(in: folder)
    #expect(!FileManager.default.fileExists(atPath: journal.path))
  }
}
