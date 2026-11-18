import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let tableDomain = "SER0000AAAA|Internal|vol0"

/// A new, empty store folder for one test.
private func store() -> URL {
  FileManager.default.temporaryDirectory.appending(
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

    let ids = await table.listed(try path("/D"), children: [try path("/D/a"), try path("/D/c")])

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
    ids += await table.listed(.root, children: try names.map { try RemotePath.root.appending($0) })

    for id in ids {
      #expect(UUID(uuidString: id.rawValue)?.uuidString == id.rawValue)
      for name in names {
        #expect(!id.rawValue.contains(name))
      }
    }
    #expect(Set(ids).count == names.count)
    // Nor does the table's file name carry the device serial.
    let file = ItemTable.file(for: tableDomain, in: folder).lastPathComponent
    #expect(!file.contains("SER0000AAAA"))
    #expect(ItemID(rawValue: "/Secret Plans") == nil)
  }

  @Test func discardAllRemovesTablesNeverLoaded() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let id = await ItemTable(domain: tableDomain, store: folder).id(for: try path("/a"))

    ItemTable.discardAll(in: folder)

    #expect(await ItemTable(domain: tableDomain, store: folder).path(for: id) == nil)
  }
}
