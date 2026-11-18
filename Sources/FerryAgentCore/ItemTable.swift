import CryptoKit
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ItemTable")

/// One domain's item identifiers and the storage paths they stand for.
///
/// An item gets a random identifier the first time the agent reports it, and keeps it when Ferry
/// renames or moves it. Deleting an item, or a listing that no longer shows it, forgets it, so a
/// change made on the phone itself shows up as a new item. The root is always `ItemID.root`.
///
/// The table is saved after every change, atomically, to one file per domain in `store`, named
/// by a hash of the domain so the device's serial is not in it. A missing file is an empty table;
/// an unreadable or inconsistent one is logged and replaced by an empty one, which costs Finder
/// its cached items for the domain but nothing on the device.
///
/// `gate` orders the operations that resolve an identifier, change the device and then update
/// the table, so none of them sees the table and the device disagree (see `AgentService`).
actor ItemTable {
  private struct Stored: Codable {
    var items: [String: RemotePath]
  }

  nonisolated let gate = OperationGate()

  private let file: URL
  private var paths: [ItemID: RemotePath] = [:]
  private var ids: [RemotePath: ItemID] = [:]
  /// Set by `discard`: nothing is written any more.
  private var discarded = false

  init(domain: String, store: URL) {
    file = Self.file(for: domain, in: store)
    (paths, ids) = Self.load(file)
  }

  /// The file holding `domain`'s table.
  static func file(for domain: String, in store: URL) -> URL {
    let digest = SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
    return store.appending(path: "\(digest).json", directoryHint: .notDirectory)
  }

  /// Deletes `domain`'s table file, for a domain whose table is not loaded.
  static func discard(domain: String, in store: URL) {
    remove(file(for: domain, in: store))
  }

  /// Deletes every table file in `store`, including ones no table in this process loaded.
  static func discardAll(in store: URL) {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: store, includingPropertiesForKeys: nil)
    } catch CocoaError.fileReadNoSuchFile {
      return
    } catch {
      log.error("listing item tables failed: \(error, privacy: .public)")
      return
    }
    for file in files where file.pathExtension == "json" {
      remove(file)
    }
  }

  /// The item's identifier, assigning a new one if it has none.
  func id(for path: RemotePath) -> ItemID {
    if path == .root { return .root }
    if let id = ids[path] { return id }
    let id = assign(path)
    save()
    return id
  }

  /// `nil` when the table does not know `id`: the item was deleted, or never reported.
  func path(for id: ItemID) -> RemotePath? {
    id == .root ? .root : paths[id]
  }

  /// Records that the item at `from`, and everything inside it, is now at `to`, keeping their
  /// identifiers. Anything the table had at `to` is gone: the device just put this item there.
  func moved(_ from: RemotePath, to: RemotePath) {
    guard from != to, from != .root else { return }
    let moving = subtree(of: from)
    forget(subtree(of: to).filter { moving[$0.key] == nil })
    for path in moving.keys {
      ids[path] = nil
    }
    for (path, id) in moving {
      guard let moved = path.rebased(from: from, to: to) else { continue }
      paths[id] = moved
      ids[moved] = id
    }
    save()
  }

  /// Forgets the item at `path` and everything inside it.
  func removed(_ path: RemotePath) {
    guard path != .root else { return }
    forget(subtree(of: path))
    save()
  }

  /// Records a listing of `folder`, whose items are `children`: forgets the children it no
  /// longer shows, with everything inside them, and returns the identifier of each of
  /// `children`, in order.
  @discardableResult func listed(_ folder: RemotePath, children: [RemotePath]) -> [ItemID] {
    let shown = Set(children)
    for path in ids.keys where path.parent == folder && !shown.contains(path) {
      forget(subtree(of: path))
    }
    let result = children.map { ids[$0] ?? assign($0) }
    save()
    return result
  }

  /// Deletes the table's file and stops writing it, so a request still running cannot bring it
  /// back after the domain is removed.
  func discard() {
    discarded = true
    Self.remove(file)
  }

  // MARK: Private

  private func assign(_ path: RemotePath) -> ItemID {
    let id = ItemID.random()
    paths[id] = path
    ids[path] = id
    return id
  }

  /// The entries for `path` and every path inside it.
  private func subtree(of path: RemotePath) -> [RemotePath: ItemID] {
    ids.filter { $0.key.isWithin(path) }
  }

  private func forget(_ entries: [RemotePath: ItemID]) {
    for (path, id) in entries {
      ids[path] = nil
      paths[id] = nil
    }
  }

  private func save() {
    guard !discarded else { return }
    let stored = Stored(
      items: Dictionary(uniqueKeysWithValues: paths.map { ($0.key.rawValue, $0.value) }))
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    } catch {
      log.error("saving item table failed: \(error, privacy: .public)")
    }
  }

  private static func load(_ file: URL) -> ([ItemID: RemotePath], [RemotePath: ItemID]) {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return ([:], [:])
    } catch {
      log.error("reading item table failed: \(error, privacy: .public)")
      return ([:], [:])
    }
    do {
      let stored = try JSONDecoder().decode(Stored.self, from: data)
      var paths: [ItemID: RemotePath] = [:]
      var ids: [RemotePath: ItemID] = [:]
      for (raw, path) in stored.items {
        guard let id = ItemID(rawValue: raw), id != .root, path != .root, ids[path] == nil else {
          throw CocoaError(.fileReadCorruptFile)
        }
        paths[id] = path
        ids[path] = id
      }
      return (paths, ids)
    } catch {
      log.error("item table is unreadable, starting empty: \(error, privacy: .public)")
      return ([:], [:])
    }
  }

  private static func remove(_ file: URL) {
    do {
      try FileManager.default.removeItem(at: file)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      log.error("deleting item table failed: \(error, privacy: .public)")
    }
  }
}
