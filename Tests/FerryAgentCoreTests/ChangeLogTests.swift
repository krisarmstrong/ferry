import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private func entry(_ id: ItemID, _ name: String, size: UInt64 = 1) throws -> ProviderEntry {
  ProviderEntry(
    id: id, parent: .root,
    item: RemoteItem(
      path: try RemotePath.root.appending(name), kind: .file, size: size,
      modified: Date(timeIntervalSince1970: 1_700_000_000)))
}

struct ChangeLogTests {
  @Test func sinceNilReturnsAnchorOnly() throws {
    var log = ChangeLog()
    log.record(.updated(try entry(.random(), "a")))

    let current = log.changes(since: nil)

    #expect(current.updated.isEmpty && current.deleted.isEmpty && !current.expired)
    #expect(log.changes(since: current.anchor) == current)
  }

  @Test func changesSinceAnchorKeepEachItemsLatest() throws {
    var log = ChangeLog()
    let (kept, gone, other) = (ItemID.random(), ItemID.random(), ItemID.random())
    log.record(.updated(try entry(other, "before")))
    let anchor = log.anchor
    log.record(.updated(try entry(kept, "a", size: 1)))
    log.record(.updated(try entry(gone, "b")))
    log.record(.updated(try entry(kept, "a", size: 2)))
    log.record(.deleted(gone))

    let since = log.changes(since: anchor)

    #expect(since.updated == [try entry(kept, "a", size: 2)])
    #expect(since.deleted == [gone])
    #expect(!since.expired)
    #expect(since.anchor == log.anchor)
  }

  @Test func anchorFromAnotherEpochIsExpired() throws {
    var earlier = ChangeLog(epoch: UUID())
    earlier.record(.deleted(.random()))
    let current = ChangeLog(epoch: UUID())

    #expect(current.changes(since: earlier.anchor).expired)
    #expect(current.changes(since: Data("junk".utf8)).expired)
    // An anchor ahead of the log was not issued by it.
    let epoch = UUID()
    var ahead = ChangeLog(epoch: epoch)
    ahead.record(.deleted(.random()))
    #expect(ChangeLog(epoch: epoch).changes(since: ahead.anchor).expired)
  }

  @Test func windowOverflowIsExpired() throws {
    var log = ChangeLog(capacity: 3)
    let start = log.anchor
    log.record(.deleted(.random()))
    let afterOne = log.anchor
    for _ in 0..<3 { log.record(.deleted(.random())) }

    // Four changes into a window of three: the first is gone, so only `start` missed one.
    #expect(log.changes(since: start).expired)
    #expect(log.changes(since: afterOne).deleted.count == 3)

    // Compaction keeps the window right.
    for _ in 0..<10 { log.record(.deleted(.random())) }
    let recent = log.anchor
    log.record(.deleted(.random()))
    #expect(log.changes(since: recent).deleted.count == 1)
    #expect(log.changes(since: afterOne).expired)
  }
}
