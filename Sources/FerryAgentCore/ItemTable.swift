import CryptoKit
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ItemTable")

/// An item's kind, size and date as the device last reported them.
private struct ReportedItem: Codable, Equatable {
  let kind: ItemKind
  let size: UInt64
  let modified: Date
}

/// One domain's item identifiers, the storage paths they stand for, and the recent changes to
/// them.
///
/// An item gets a random identifier the first time the agent reports it, and keeps it when Ferry
/// renames or moves it, or a file's contents change. Deleting an item, or a listing that no
/// longer shows it, forgets it. An item whose kind changed (a file where a folder was), or a new
/// item Ferry creates where a stale entry was, gets a new identifier: it is not the item Finder
/// knew. The root is always `ItemID.root`.
///
/// Every new or changed item, and every forgotten one, is recorded in the domain's `ChangeLog`,
/// which feeds FileProvider's working set.
///
/// The table is saved atomically after each operation that changed it, to one file per domain in
/// `store`, named by a hash of the domain so the device's serial is not in it. A missing file is
/// an empty table; an unreadable or inconsistent one is logged and replaced by an empty one,
/// which costs Finder its cached items for the domain but nothing on the device.
///
/// `gate` orders the operations that resolve an identifier, change the device and then update
/// the table, so none of them sees the table and the device disagree (see `AgentService`).
actor ItemTable {
  /// What the table knows about one item. `reported` is `nil` for an item known only as the
  /// parent of one the agent reported.
  private struct Record: Codable, Equatable {
    var path: RemotePath
    var reported: ReportedItem?

    init(path: RemotePath, item: RemoteItem? = nil) {
      self.path = path
      reported = item.map { ReportedItem(kind: $0.kind, size: $0.size, modified: $0.modified) }
    }

    func describes(_ item: RemoteItem) -> Bool {
      reported == ReportedItem(kind: item.kind, size: item.size, modified: item.modified)
    }

    /// The item as last reported, at its current path.
    var item: RemoteItem? {
      reported.map {
        RemoteItem(path: path, kind: $0.kind, size: $0.size, modified: $0.modified)
      }
    }
  }

  private struct Stored: Codable {
    var items: [String: Record]
  }

  nonisolated let gate = OperationGate()

  private let file: URL
  private var records: [ItemID: Record] = [:]
  private var ids: [RemotePath: ItemID] = [:]
  private var changeLog: ChangeLog
  /// Changed since the last save.
  private var dirty = false
  /// Set by `discard`: nothing is written any more.
  private var discarded = false

  init(domain: String, store: URL, changes: ChangeLog = ChangeLog()) {
    file = Self.file(for: domain, in: store)
    changeLog = changes
    (records, ids) = Self.load(file)
  }

  /// The number of changes recorded so far.
  var changeCount: UInt64 { changeLog.sequence }

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
      log.error("listing item tables failed: \(error, privacy: .private)")
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
    defer { save() }
    return assign(Record(path: path))
  }

  /// `nil` when the table does not know `id`: the item was deleted, or never reported.
  func path(for id: ItemID) -> RemotePath? {
    id == .root ? .root : records[id]?.path
  }

  /// `item` as the device reports it now, with its identifier: the one it had, unless its kind
  /// changed. A new or changed item is recorded as a change.
  func observed(_ item: RemoteItem) -> ProviderEntry {
    defer { save() }
    return observe(item)
  }

  /// An item Ferry just made at a path the device had free. Whatever the table had there is
  /// stale and forgotten, so the new item never takes an old identifier.
  func created(_ item: RemoteItem) -> ProviderEntry {
    defer { save() }
    if ids[item.path] != nil {
      forget(subtree(of: item.path))
    }
    return observe(item)
  }

  /// `item` is the state of the item `id` after Ferry changed it in place (renamed, moved, or
  /// replaced its contents, after `moved` for the first two). Recorded as a change.
  func changed(_ item: RemoteItem, id: ItemID) -> ProviderEntry {
    defer { save() }
    records[id] = Record(path: item.path, item: item)
    ids[item.path] = id
    dirty = true
    let entry = entry(item, id: id)
    changeLog.record(.updated(entry))
    return entry
  }

  /// Records that the item at `from`, and everything inside it, is now at `to`, keeping their
  /// identifiers. Anything the table had at `to` is gone: the device just put this item there.
  func moved(_ from: RemotePath, to: RemotePath) {
    guard from != to, from != .root else { return }
    defer { save() }
    let moving = subtree(of: from)
    forget(subtree(of: to).filter { moving[$0.key] == nil })
    for path in moving.keys {
      ids[path] = nil
    }
    for (path, id) in moving {
      guard let moved = path.rebased(from: from, to: to) else { continue }
      records[id]?.path = moved
      ids[moved] = id
      dirty = true
    }
  }

  /// Forgets the item at `path` and everything inside it.
  func removed(_ path: RemotePath) {
    guard path != .root else { return }
    defer { save() }
    forget(subtree(of: path))
  }

  /// Records a listing of `folder`, whose items are `children`: forgets the children it no
  /// longer shows, with everything inside them, and returns each child with its identifier, in
  /// order.
  func listed(_ folder: RemotePath, children: [RemoteItem]) -> [ProviderEntry] {
    defer { save() }
    let shown = Set(children.map(\.path))
    for path in ids.keys where path.parent == folder && !shown.contains(path) {
      forget(subtree(of: path))
    }
    return children.map(observe)
  }

  /// At most `size` items after `cursor` in identifier order, and the cursor for the next page
  /// if there is one: the last identifier returned. A cursor, unlike an offset, still finds the
  /// right place after items before it are forgotten, so a page never skips one. Only items the
  /// agent reported are in it, not the root or a folder known only as some item's parent.
  func workingSet(after cursor: ItemID?, size: Int) -> (entries: [ProviderEntry], next: ItemID?) {
    let remaining = records.compactMap { id, record -> (id: ItemID, item: RemoteItem)? in
      guard let item = record.item, cursor.map({ id.rawValue > $0.rawValue }) ?? true else {
        return nil
      }
      return (id, item)
    }.sorted { $0.id.rawValue < $1.id.rawValue }
    let page = remaining.prefix(size)
    return (page.map { entry($0.item, id: $0.id) }, remaining.count > size ? page.last?.id : nil)
  }

  /// The changes recorded after `anchor`; see `ChangeLog`.
  func changes(since anchor: Data?) -> ChangeLog.Since {
    changeLog.changes(since: anchor)
  }

  /// Deletes the table's file and stops writing it, so a request still running cannot bring it
  /// back after the domain is removed.
  func discard() {
    discarded = true
    Self.remove(file)
  }

  // MARK: Private

  private func observe(_ item: RemoteItem) -> ProviderEntry {
    if item.path == .root { return ProviderEntry(id: .root, parent: .root, item: item) }
    let id: ItemID
    if let known = ids[item.path], let record = records[known] {
      if record.describes(item) { return entry(item, id: known) }
      if let kind = record.reported?.kind, kind != item.kind {
        forget(subtree(of: item.path))
        id = assign(Record(path: item.path, item: item))
      } else {
        id = known
        records[id] = Record(path: item.path, item: item)
        dirty = true
      }
    } else {
      id = assign(Record(path: item.path, item: item))
    }
    let entry = entry(item, id: id)
    changeLog.record(.updated(entry))
    return entry
  }

  private func entry(_ item: RemoteItem, id: ItemID) -> ProviderEntry {
    let parent = item.path.parent ?? .root
    let parentID: ItemID
    if parent == .root {
      parentID = .root
    } else if let known = ids[parent] {
      parentID = known
    } else {
      parentID = assign(Record(path: parent))
    }
    return ProviderEntry(id: id, parent: parentID, item: item)
  }

  private func assign(_ record: Record) -> ItemID {
    let id = ItemID.random()
    records[id] = record
    ids[record.path] = id
    dirty = true
    return id
  }

  /// The entries for `path` and every path inside it.
  private func subtree(of path: RemotePath) -> [RemotePath: ItemID] {
    ids.filter { $0.key.isWithin(path) }
  }

  /// Forgets `entries`, recording each as deleted.
  private func forget(_ entries: [RemotePath: ItemID]) {
    for (path, id) in entries {
      ids[path] = nil
      records[id] = nil
      changeLog.record(.deleted(id))
      dirty = true
    }
  }

  private func save() {
    guard dirty, !discarded else { return }
    dirty = false
    let stored = Stored(
      items: Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) }))
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    } catch {
      log.error("saving item table failed: \(error, privacy: .private)")
    }
  }

  private static func load(_ file: URL) -> ([ItemID: Record], [RemotePath: ItemID]) {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return ([:], [:])
    } catch {
      log.error("reading item table failed: \(error, privacy: .private)")
      return ([:], [:])
    }
    do {
      let stored = try JSONDecoder().decode(Stored.self, from: data)
      var records: [ItemID: Record] = [:]
      var ids: [RemotePath: ItemID] = [:]
      for (raw, record) in stored.items {
        guard let id = ItemID(rawValue: raw), id != .root, record.path != .root,
          ids[record.path] == nil
        else { throw CocoaError(.fileReadCorruptFile) }
        records[id] = record
        ids[record.path] = id
      }
      return (records, ids)
    } catch {
      log.error("item table is unreadable, starting empty: \(error, privacy: .private)")
      return ([:], [:])
    }
  }

  private static func remove(_ file: URL) {
    do {
      try FileManager.default.removeItem(at: file)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      log.error("deleting item table failed: \(error, privacy: .private)")
    }
  }
}
