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
  /// parent of one the agent reported. `listed` marks a folder the agent has listed for a client,
  /// which a refresh lists again.
  fileprivate struct Record: Codable, Equatable {
    var path: RemotePath
    var reported: ReportedItem?
    var listed: Bool
    /// The size a download delivered when the device lists the file as smaller: its metadata
    /// is stale. Listings that still say `listed` at `modified` mean this size.
    var received: ReceivedSize?

    init(path: RemotePath, item: RemoteItem? = nil, listed: Bool = false) {
      self.path = path
      reported = item.map { ReportedItem(kind: $0.kind, size: $0.size, modified: $0.modified) }
      self.listed = listed
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

  fileprivate struct ReceivedSize: Codable, Equatable {
    let listed: UInt64
    let modified: Date
    let actual: UInt64
  }

  fileprivate struct Stored: Codable {
    var items: [String: Record]
    var rootListed: Bool
  }

  nonisolated let gate = OperationGate()

  private let file: URL
  private var records: [ItemID: Record] = [:]
  private var ids: [RemotePath: ItemID] = [:]
  private var rootListed = false
  private var changeLog: ChangeLog
  /// Changed since the last save.
  private var dirty = false
  /// Set by `discard`: nothing is written any more.
  private var discarded = false

  init(domain: String, store: URL, changes: ChangeLog = ChangeLog()) {
    file = Self.file(for: domain, in: store)
    changeLog = changes
    let loaded = Self.load(file)
    (records, ids, rootListed) = (loaded.records, loaded.ids, loaded.rootListed)
  }

  /// The number of changes recorded so far.
  var changeCount: UInt64 { changeLog.sequence }

  /// The item's identifier, assigning a new one if it has none.
  func id(for path: RemotePath) -> ItemID {
    if path == .root { return .root }
    if let id = ids[path] { return id }
    defer { save() }
    return assign(Record(path: path))
  }

  /// The folders the agent has listed for a client, root included, parents before their
  /// children: what a refresh lists again. Not every folder a listing showed: listing those too
  /// would walk one level deeper with each refresh.
  func knownFolders() -> [RemotePath] {
    let folders = records.values.filter { $0.listed && $0.reported?.kind == .folder }.map(\.path)
    return (rootListed ? [.root] : [])
      + folders.sorted {
        ($0.components.count, $0.description) < ($1.components.count, $1.description)
      }
  }

  /// Whether the table still knows the item at `path`.
  func knows(_ path: RemotePath) -> Bool {
    path == .root || ids[path] != nil
  }

  /// Whether the agent last reported `item` to FileProvider as it is now: a file of the same size
  /// (as a download corrected it) and date, or a folder (whose date changes with what it holds).
  func reportedAsIs(_ item: RemoteItem) -> Bool {
    guard let id = ids[item.path], let reported = records[id]?.item else { return false }
    return Self.corrected(item, by: records[id]?.received).matches(reported)
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

  /// A file just downloaded, at the size that arrived. If that is more than the device lists,
  /// the table remembers it, so later listings with the same stale size and date keep reporting
  /// the real one and Finder does not see the file change back and forth.
  func downloaded(_ download: Downloaded) -> ProviderEntry {
    defer { save() }
    let listed = download.listed
    if let id = ids[listed.path], records[id] != nil {
      records[id]?.received =
        download.received == listed.size
        ? nil
        : ReceivedSize(listed: listed.size, modified: listed.modified, actual: download.received)
      dirty = true
    }
    return observe(download.item)
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
    records[id] = Record(path: item.path, item: item, listed: records[id]?.listed ?? false)
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
    markListed(folder)
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

  private func observe(_ reported: RemoteItem) -> ProviderEntry {
    if reported.path == .root { return ProviderEntry(id: .root, parent: .root, item: reported) }
    var item = reported
    let id: ItemID
    if let known = ids[item.path], let record = records[known] {
      item = Self.corrected(item, by: record.received)
      if record.describes(item) { return entry(item, id: known) }
      if let kind = record.reported?.kind, kind != item.kind {
        forget(subtree(of: item.path))
        id = assign(Record(path: item.path, item: item))
      } else {
        id = known
        var updated = Record(path: item.path, item: item, listed: record.listed)
        // Still the same stale listing: keep reading it as the size that arrived.
        updated.received = record.received.flatMap { $0.modified == item.modified ? $0 : nil }
        records[id] = updated
        dirty = true
      }
    } else {
      id = assign(Record(path: item.path, item: item))
    }
    let entry = entry(item, id: id)
    changeLog.record(.updated(entry))
    return entry
  }

  /// `item` at the size a download delivered, if the device still lists it as it did then.
  private static func corrected(_ item: RemoteItem, by received: ReceivedSize?) -> RemoteItem {
    guard let received, item.kind == .file, item.size == received.listed,
      item.modified == received.modified
    else { return item }
    return RemoteItem(
      path: item.path, kind: item.kind, size: received.actual, modified: item.modified)
  }

  private func markListed(_ folder: RemotePath) {
    if folder == .root {
      guard !rootListed else { return }
      rootListed = true
    } else {
      guard let id = ids[folder], records[id]?.listed == false else { return }
      records[id]?.listed = true
    }
    dirty = true
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
      items: Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) }),
      rootListed: rootListed)
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    } catch {
      log.error("saving item table failed: \(error, privacy: .private)")
    }
  }

}

extension ItemTable {
  /// A table as read from its file.
  fileprivate struct Loaded {
    var records: [ItemID: Record] = [:]
    var ids: [RemotePath: ItemID] = [:]
    var rootListed = false
  }

  fileprivate static func load(_ file: URL) -> Loaded {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return Loaded()
    } catch {
      log.error("reading item table failed: \(error, privacy: .private)")
      return Loaded()
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
      return Loaded(records: records, ids: ids, rootListed: stored.rootListed)
    } catch {
      log.error("item table is unreadable, starting empty: \(error, privacy: .private)")
      return Loaded()
    }
  }
}
