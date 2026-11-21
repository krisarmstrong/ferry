import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The item table's cost per change and per working-set page on large tables (audit H1, M10).
///
/// Both sizes are measured and printed; the test asserts an upper bound per operation on the
/// 40,000-item table. A cost that grows with the table (a whole-file rewrite, a sort per page)
/// was 60-300 ms per change there in a release build, far above it. The bound is loose, since
/// CI runs a debug build on shared runners, and the ratio between sizes is printed but not
/// asserted: a journal fold now and then makes single runs swing. For the release numbers run
/// `swift test -c release -Xswiftc -enable-testing --filter ItemTableBenchmarkTests`.
@Suite(.serialized)
struct ItemTableBenchmarkTests {
  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
  private static let folderSize = 1_000

  private struct Costs {
    var observe: Duration
    var create: Duration
    var remove: Duration
    var relist: Duration
    var workingSetPage: Duration
    var workingSetPass: Duration
    /// Folding the journal into a snapshot of the whole table, once per about a table's worth
    /// of appended changes.
    var fold: Duration
    /// The first listing of a new folder of 20,000 items: 20,000 new identifiers at once.
    var bigListing: Duration
  }

  /// One operation's cost at both sizes, and its bound at 40,000 items.
  private struct Row {
    let name: String
    let at10k: Duration
    let at40k: Duration
    let bound: Double
  }

  private func item(_ folder: Int, _ index: Int) throws -> RemoteItem {
    RemoteItem(
      path: try path("/F\(folder)/file\(index).jpg"), kind: .file, size: 1, modified: Self.stamp)
  }

  /// A table of `count` files in folders of `folderSize`, as listings record them.
  private func table(_ count: Int) async throws -> (ItemTable, [[RemoteItem]]) {
    let table = ItemTable(
      domain: "SER0000BENCH|Internal|vol0",
      store: TestScratch.root.appending(
        path: "ferry-bench-\(UUID().uuidString)", directoryHint: .isDirectory))
    var folders: [[RemoteItem]] = []
    for folder in 0..<(count / Self.folderSize) {
      let children = try (0..<Self.folderSize).map { try item(folder, $0) }
      _ = await table.listed(try path("/F\(folder)"), children: children)
      folders.append(children)
    }
    return (table, folders)
  }

  private func measure(_ count: Int, changes: Int = 50) async throws -> Costs {
    let (table, folders) = try await table(count)
    let clock = ContinuousClock()
    let observe = try await clock.measure {
      for index in 0..<changes {
        _ = await table.observed(
          RemoteItem(
            path: try path("/F0/file\(index).jpg"), kind: .file, size: 2, modified: Self.stamp))
      }
    }
    let create = try await clock.measure {
      for index in 0..<changes {
        _ = await table.created(
          RemoteItem(
            path: try path("/F1/new\(index).jpg"), kind: .file, size: 1, modified: Self.stamp))
      }
    }
    let remove = try await clock.measure {
      for index in 0..<changes {
        await table.removed(try path("/F2/file\(index).jpg"))
      }
    }
    let relist = try await clock.measure {
      for _ in 0..<5 {
        _ = await table.listed(try path("/F3"), children: folders[3])
      }
    }
    var pages = 0
    let pass = await clock.measure {
      var cursor: ItemID?
      repeat {
        let page = await table.workingSet(after: cursor, size: 500)
        cursor = page.next
        pages += 1
      } while cursor != nil
    }
    let fold = try await clock.measure {
      await table.foldOnNextSave()
      _ = await table.observed(
        RemoteItem(path: try path("/F0/file0.jpg"), kind: .file, size: 3, modified: Self.stamp))
    }
    let big = try (0..<20_000).map {
      RemoteItem(path: try path("/Big/f\($0).jpg"), kind: .file, size: 1, modified: Self.stamp)
    }
    let bigListing = try await clock.measure {
      _ = await table.listed(try path("/Big"), children: big)
    }
    return Costs(
      observe: observe / changes, create: create / changes, remove: remove / changes,
      relist: relist / 5, workingSetPage: pass / pages, workingSetPass: pass, fold: fold,
      bigListing: bigListing)
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
  }

  @Test func aChangeOnALargeTableStaysCheap() async throws {
    let small = try await measure(10_000)
    let large = try await measure(40_000)
    // Each row with its bound at 40,000 items, in a debug build on a busy runner: one change,
    // one page, or one listing of 1,000 items (1,000 lookups).
    let rows = [
      Row(name: "observed", at10k: small.observe, at40k: large.observe, bound: 50),
      Row(name: "created", at10k: small.create, at40k: large.create, bound: 50),
      Row(name: "removed", at10k: small.remove, at40k: large.remove, bound: 50),
      Row(name: "listed (unchanged 1,000)", at10k: small.relist, at40k: large.relist, bound: 250),
      Row(
        name: "working-set page (500)", at10k: small.workingSetPage, at40k: large.workingSetPage,
        bound: 50),
    ]
    for row in rows {
      print(
        String(
          format: "ItemTable benchmark: %@ %.3f ms at 10,000, %.3f ms at 40,000", row.name,
          milliseconds(row.at10k), milliseconds(row.at40k)))
    }
    for (name, at10k, at40k) in [
      ("working-set pass", small.workingSetPass, large.workingSetPass),
      ("journal fold", small.fold, large.fold),
      ("first listing of 20,000 new items", small.bigListing, large.bigListing),
    ] {
      print(
        String(
          format: "ItemTable benchmark: %@ %.1f ms at 10,000, %.1f ms at 40,000", name,
          milliseconds(at10k), milliseconds(at40k)))
    }
    // Inserting new identifiers one at a time into the order was O(n) each, so a big new
    // folder cost O(n²); in a debug build this stays well under a second.
    #expect(milliseconds(large.bigListing) < 5_000)
    for row in rows {
      #expect(
        milliseconds(row.at40k) < row.bound,
        "\(row.name) costs \(milliseconds(row.at40k)) ms at 40,000")
    }
  }
}
