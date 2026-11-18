import FerryIPC
import Foundation

/// The recent changes to one domain's items, for FileProvider's working-set enumeration.
///
/// A replicated extension learns about changes made outside it only by enumerating the working
/// set from a sync anchor. Each recorded change gets the next sequence number; an anchor names a
/// sequence number and the log that issued it, by a random epoch each log draws when created.
/// The log lives in memory and keeps the last `capacity` changes, so an anchor from an earlier
/// agent process or an earlier table of the domain, or one older than the window, is expired,
/// and FileProvider enumerates everything again.
struct ChangeLog {
  enum Change: Equatable {
    case updated(ProviderEntry)
    case deleted(ItemID)

    var id: ItemID {
      switch self {
      case .updated(let entry): entry.id
      case .deleted(let id): id
      }
    }
  }

  /// What changed since an anchor. `expired` means the anchor cannot be answered and the lists
  /// are empty.
  struct Since: Equatable {
    let anchor: Data
    let updated: [ProviderEntry]
    let deleted: [ItemID]
    let expired: Bool
  }

  private let epoch: UUID
  private let capacity: Int
  private(set) var sequence: UInt64 = 0
  /// Recorded changes; the ones before `start` are dropped and wait to be compacted away.
  private var changes: [(sequence: UInt64, change: Change)] = []
  private var start = 0
  /// The sequence number of the newest dropped change: an anchor before it has missed changes.
  private var droppedThrough: UInt64 = 0

  init(epoch: UUID = UUID(), capacity: Int = 10_000) {
    self.epoch = epoch
    self.capacity = capacity
  }

  /// The epoch's 16 bytes, then the sequence number as 8 big-endian bytes.
  var anchor: Data {
    var data = withUnsafeBytes(of: epoch.uuid) { Data($0) }
    withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
    return data
  }

  mutating func record(_ change: Change) {
    sequence += 1
    changes.append((sequence, change))
    if changes.count - start > capacity {
      droppedThrough = changes[start].sequence
      start += 1
    }
    if start >= capacity {
      changes.removeFirst(start)
      start = 0
    }
  }

  /// The changes after `anchor`, each item's last one only. `nil` returns the current anchor and
  /// no changes.
  func changes(since anchor: Data?) -> Since {
    guard let anchor else {
      return Since(anchor: self.anchor, updated: [], deleted: [], expired: false)
    }
    guard let since = Self.sequence(in: anchor, epoch: epoch), since <= sequence,
      since >= droppedThrough
    else {
      return Since(anchor: self.anchor, updated: [], deleted: [], expired: true)
    }
    var latest: [ItemID: (order: Int, change: Change)] = [:]
    for (order, recorded) in changes[start...].enumerated()
    where recorded.sequence > since {
      latest[recorded.change.id] = (order, recorded.change)
    }
    var updated: [ProviderEntry] = []
    var deleted: [ItemID] = []
    for (_, change) in latest.values.sorted(by: { $0.order < $1.order }) {
      switch change {
      case .updated(let entry): updated.append(entry)
      case .deleted(let id): deleted.append(id)
      }
    }
    return Since(anchor: self.anchor, updated: updated, deleted: deleted, expired: false)
  }

  /// The sequence number in `anchor`, or `nil` if it is malformed or from another epoch.
  private static func sequence(in anchor: Data, epoch: UUID) -> UInt64? {
    let current = withUnsafeBytes(of: epoch.uuid) { Data($0) }
    guard anchor.count == 24, anchor.prefix(16) == current else { return nil }
    return anchor.suffix(8).reduce(0) { $0 << 8 | UInt64($1) }
  }
}
