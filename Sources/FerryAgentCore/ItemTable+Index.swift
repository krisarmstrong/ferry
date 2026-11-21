import DeviceKit
import FerryIPC
import Foundation

// MARK: Records, paths and order

extension ItemTable {
  /// Stores `record` as `id`'s, keeping `order` in step for an identifier new to the table.
  func put(_ record: Record, for id: ItemID) {
    if records.updateValue(record, forKey: id) == nil {
      order.insert(id, at: order.firstIndex(after: id))
    }
    touch(id)
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
    // A few identifiers are found by search; a large subtree costs one pass over the order.
    if entries.count <= Self.searchedRemovals {
      for id in entries.values {
        let index = order.firstIndex(after: id) - 1
        if index >= 0, order[index] == id { order.remove(at: index) }
      }
    } else {
      let gone = Set(entries.values)
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
