import DeviceKit
import FerryIPC
import Foundation

// MARK: Records, paths and order

extension ItemTable {
  /// Stores `record` as `id`'s. An identifier new to the table waits in `unordered` until the
  /// order is next read, so a listing of many new items sorts them once instead of shifting the
  /// order for each.
  func put(_ record: Record, for id: ItemID) {
    if records.updateValue(record, forKey: id) == nil {
      unordered.insert(id)
    }
    touch(id)
  }

  /// Merges the identifiers waiting in `unordered` into `order`.
  func settleOrder() {
    guard !unordered.isEmpty else { return }
    let new = unordered.sorted { $0.rawValue < $1.rawValue }
    unordered = []
    var merged: [ItemID] = []
    merged.reserveCapacity(order.count + new.count)
    var (old, added) = (order.startIndex, new.startIndex)
    while old < order.endIndex, added < new.endIndex {
      if order[old].rawValue < new[added].rawValue {
        merged.append(order[old])
        old += 1
      } else {
        merged.append(new[added])
        added += 1
      }
    }
    merged += order[old...]
    merged += new[added...]
    order = merged
  }

  func touch(_ id: ItemID) {
    touched.insert(id)
    dirty = true
  }

  func bind(_ path: RemotePath, to id: ItemID) {
    ids[path] = id
    Self.link(path, in: &children)
  }

  func unbind(_ path: RemotePath) {
    ids[path] = nil
    unlink(path)
  }

  /// Puts `path` under its parent, and each ancestor not there yet under its own.
  static func link(_ path: RemotePath, in children: inout [RemotePath: Set<RemotePath>]) {
    var node = path
    while let parent = node.parent, children[parent, default: []].insert(node).inserted {
      node = parent
    }
  }

  /// Takes `path` out from under its parent once nothing is known at or inside it, and each
  /// ancestor that is left the same.
  func unlink(_ path: RemotePath) {
    var node = path
    while ids[node] == nil, children[node]?.isEmpty ?? true, let parent = node.parent {
      children[node] = nil
      children[parent]?.remove(node)
      node = parent
    }
  }

  /// The entries for `path` and every path inside it.
  func subtree(of path: RemotePath) -> [RemotePath: ItemID] {
    var found: [RemotePath: ItemID] = [:]
    var pending = [path]
    while let node = pending.popLast() {
      if let id = ids[node] { found[node] = id }
      pending += children[node] ?? []
    }
    return found
  }

  /// Forgets `entries`, recording each as deleted.
  func forget(_ entries: [RemotePath: ItemID]) {
    guard !entries.isEmpty else { return }
    for (path, id) in entries {
      unbind(path)
      records[id] = nil
      changeLog.record(.deleted(id))
      touch(id)
    }
    // One still waiting to be ordered just leaves the queue. Of the rest, a few are found by
    // search; a large subtree costs one pass over the order.
    let ordered = entries.values.filter { unordered.remove($0) == nil }
    if ordered.count <= Self.searchedRemovals {
      for id in ordered {
        let index = order.firstIndex(after: id) - 1
        if index >= 0, order[index] == id { order.remove(at: index) }
      }
    } else {
      let gone = Set(ordered)
      order.removeAll { gone.contains($0) }
    }
  }
}

extension [ItemID] {
  /// In an array sorted by identifier, the index of the first identifier after `id`.
  func firstIndex(after id: ItemID) -> Int {
    var (low, high) = (0, count)
    while low < high {
      let middle = (low + high) / 2
      if self[middle].rawValue > id.rawValue {
        high = middle
      } else {
        low = middle + 1
      }
    }
    return low
  }
}
