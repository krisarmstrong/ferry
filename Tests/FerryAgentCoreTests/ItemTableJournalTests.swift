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

  /// A save that cannot append (the store folder went away) writes a snapshot instead, so the
  /// table keeps being saved.
  @Test func aFailedAppendWritesASnapshot() async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let table = ItemTable(domain: tableDomain, store: folder)
    _ = await table.observed(try file("/a"))
    try FileManager.default.removeItem(at: folder)
    let later = await table.observed(try file("/b"))
    #expect(await ItemTable(domain: tableDomain, store: folder).path(for: later.id) != nil)
  }

  /// The change that folds the journal is in the new snapshot only. Each step of the fold may be
  /// the last one before a crash or power loss: the reloaded table must be either the state
  /// before that change or the state after it, never a mix (W5 review I1).
  enum FoldCrash: CaseIterable {
    /// Before the new snapshot is in place: the old snapshot and the old journal remain.
    case beforeSnapshot
    /// After the new snapshot, before the old journal is deleted.
    case afterSnapshot
    /// After both: the normal end of a fold.
    case afterJournal
  }

  @Test(arguments: FoldCrash.allCases)
  func aCrashDuringAFoldLeavesAConsistentTable(_ crash: FoldCrash) async throws {
    let folder = store()
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshot = ItemTable.file(for: tableDomain, in: folder)
    let journal = ItemTable.journal(for: tableDomain, in: folder)
    let table = ItemTable(domain: tableDomain, store: folder)
    let moving = await table.observed(try file("/x"))
    let removing = await table.observed(try file("/y"))
    // Journalled: the item moves to /a, so the journal holds it there.
    await table.moved(try path("/x"), to: try path("/a"))
    _ = await table.changed(try file("/a"), id: moving.id)
    let (oldSnapshot, oldJournal) = (try Data(contentsOf: snapshot), try Data(contentsOf: journal))

    // The fold: the item moves onto /y, which forgets the item there, in the snapshot only.
    await table.foldOnNextSave()
    await table.moved(try path("/a"), to: try path("/y"))
    #expect(!FileManager.default.fileExists(atPath: journal.path))

    switch crash {
    case .beforeSnapshot:
      try oldSnapshot.write(to: snapshot)
      try oldJournal.write(to: journal)
    case .afterSnapshot:
      try oldJournal.write(to: journal)
    case .afterJournal:
      break
    }
    let reloaded = ItemTable(domain: tableDomain, store: folder)
    let moved = await reloaded.path(for: moving.id)
    let other = await reloaded.path(for: removing.id)
    if crash == .beforeSnapshot {
      #expect(moved == (try path("/a")))
      #expect(other == (try path("/y")))
    } else {
      #expect(moved == (try path("/y")))
      #expect(other == nil)
    }
  }
}
