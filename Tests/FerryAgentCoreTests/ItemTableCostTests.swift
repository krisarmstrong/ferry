import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The item table's work per change and per working-set page does not grow with the table
/// (audit H1, M10). It is counted, not timed, so a shared machine cannot fail it: a whole-file
/// rewrite per change, a sort per page, or new identifiers inserted one at a time each show up
/// as a count that differs between 10,000 and 40,000 items. `ItemTableBenchmarkTests` reports
/// the times.
@Suite(.serialized)
struct ItemTableCostTests {
  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
  private static let folderSize = 1_000
  private static let changes = 50

  /// The work one kind of operation did, as `ItemTable.Work` counts it.
  private struct Costs: Equatable {
    var observe = ItemTable.Work()
    var create = ItemTable.Work()
    var remove = ItemTable.Work()
    var relist = ItemTable.Work()
    var firstPass = ItemTable.Work()
    var secondPass = ItemTable.Work()
    var waitingAfterBigListing = 0
    var pages = 0
  }

  private func file(_ folder: String, _ name: String, size: UInt64 = 1) throws -> RemoteItem {
    RemoteItem(path: try path("/\(folder)/\(name)"), kind: .file, size: size, modified: Self.stamp)
  }

  /// A table of `count` files in folders of `folderSize`, as listings record them, folded into
  /// its snapshot and with its order settled, so what follows starts from an empty journal.
  private func table(_ count: Int) async throws -> (ItemTable, [[RemoteItem]]) {
    let table = ItemTable(
      domain: "SER0000COST|Internal|vol0",
      store: TestScratch.root.appending(
        path: "ferry-cost-\(UUID().uuidString)", directoryHint: .isDirectory))
    var folders: [[RemoteItem]] = []
    for folder in 0..<(count / Self.folderSize) {
      let children = try (0..<Self.folderSize).map { try file("F\(folder)", "file\($0).jpg") }
      _ = await table.listed(try path("/F\(folder)"), children: children)
      folders.append(children)
    }
    await table.foldOnNextSave()
    _ = await table.created(try file("Seed", "fold.jpg"))
    _ = await table.workingSet(after: nil, size: 1)
    return (table, folders)
  }

  /// The work `operation` does on `table`.
  private func work(
    _ table: ItemTable, _ operation: () async throws -> Void
  ) async rethrows -> ItemTable.Work {
    let before = await table.work
    try await operation()
    let after = await table.work
    return ItemTable.Work(
      snapshots: after.snapshots - before.snapshots,
      snapshotRows: after.snapshotRows - before.snapshotRows,
      journalRows: after.journalRows - before.journalRows,
      sortedIDs: after.sortedIDs - before.sortedIDs)
  }

  private func costs(_ count: Int) async throws -> Costs {
    let (table, folders) = try await table(count)
    var costs = Costs()
    costs.observe = try await work(table) {
      for index in 0..<Self.changes {
        _ = await table.observed(try file("F0", "file\(index).jpg", size: 2))
      }
    }
    costs.create = try await work(table) {
      for index in 0..<Self.changes {
        _ = await table.created(try file("F1", "new\(index).jpg"))
      }
    }
    costs.remove = try await work(table) {
      for index in 0..<Self.changes {
        await table.removed(try path("/F2/file\(index).jpg"))
      }
    }
    costs.relist = try await work(table) {
      _ = await table.listed(try path("/F3"), children: folders[3])
    }
    var pages = 0
    costs.firstPass = await work(table) {
      var cursor: ItemID?
      repeat {
        let page = await table.workingSet(after: cursor, size: 500)
        cursor = page.next
        pages += 1
      } while cursor != nil
    }
    costs.pages = pages
    costs.secondPass = await work(table) {
      _ = await table.workingSet(after: nil, size: 500)
    }
    let big = try (0..<20_000).map { try file("Big", "f\($0).jpg") }
    _ = await table.listed(try path("/Big"), children: big)
    costs.waitingAfterBigListing = await table.unordered.count
    return costs
  }

  @Test func aChangeOnALargeTableCostsTheSameAsOnASmallOne() async throws {
    let small = try await costs(10_000)
    let large = try await costs(40_000)
    // Each change appends its one record to the journal; none rewrites the table.
    let oneRowEach = ItemTable.Work(journalRows: Self.changes)
    #expect(large.observe == oneRowEach)
    #expect(large.create == oneRowEach)
    #expect(large.remove == oneRowEach)
    // A listing that changed none of its 1,000 items writes only the folder's own record.
    #expect(large.relist == ItemTable.Work(journalRows: 1))
    // The pass sorts only the 50 identifiers created since the order was last settled, once,
    // however many pages it takes; the next pass sorts none.
    #expect(large.firstPass == ItemTable.Work(sortedIDs: Self.changes))
    #expect(large.secondPass == ItemTable.Work())
    // A big new folder's identifiers, its 20,000 items and the folder itself, wait to be sorted
    // together, not inserted one at a time.
    #expect(large.waitingAfterBigListing == 20_001)
    // None of it depends on the table's size, but for the pages a pass takes.
    var scaled = small
    scaled.pages = large.pages
    #expect(scaled == large)
  }

  /// A journal past its size is folded into one snapshot of the whole table, and emptied.
  @Test func aFoldWritesTheTableOnce() async throws {
    let (table, _) = try await table(10_000)
    let rows = await table.records.count
    let fold = try await work(table) {
      await table.foldOnNextSave()
      _ = await table.observed(try file("F0", "file0.jpg", size: 3))
    }
    #expect(fold == ItemTable.Work(snapshots: 1, snapshotRows: rows))
    #expect(await table.journalBytes == 0)
  }
}
