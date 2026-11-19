import DeviceKit
import Foundation
import os

/// A `DeviceSession` over one MTP device: turns storage-relative paths into object IDs and back.
///
/// Storages are addressed by `StorageID.key`; the raw MTP storage ID is a per-connection detail
/// that never leaves the session. Every mutation invalidates the cached listing of each folder it
/// touched, whether or not it succeeded, since a failed transfer can still leave an object behind;
/// a delete that succeeded only takes its object out of its folder's listing.
///
/// Public operations run one at a time through `gate`, so a check and the action it guards are
/// never split by another operation. They must not call each other: the gate is not reentrant.
/// Once the device reports it is gone, the session closes it and fails every later call at once.
/// The move fallback lives in `MTPSession+Move.swift`, so the helpers it shares are internal.
actor MTPSession: DeviceSession {
  static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "MTPSession")

  nonisolated let method = ConnectionMethod.usbFileTransfer

  nonisolated let info: DeviceInfo
  nonisolated let partials: PartialRegistry
  let device: any MTPDeviceOperations
  /// Where a move on a device without MoveObject keeps its local copy (see `copyThenDelete`).
  let scratch: URL
  let resolver: PathResolver
  private let gate = OperationGate()
  /// Raw storage ID by `StorageID.key`, refreshed by `refreshStorages()`.
  private var rawStorages: [String: UInt32] = [:]
  private var disconnected = false
  /// Tells the transport the device is free again; runs once, when the handle is released.
  private var onRelease: (@Sendable () async -> Void)?

  init(
    device: any MTPDeviceOperations, scratch: URL, partials: PartialRegistry = PartialRegistry(),
    onRelease: @escaping @Sendable () async -> Void = {}
  ) {
    self.info = device.info
    self.partials = partials
    self.device = device
    self.scratch = scratch
    self.onRelease = onRelease
    self.resolver = PathResolver { storage, parent throws(TransportError) in
      try await device.list(storage: storage, parent: parent)
    }
  }

  func capabilities() async -> DeviceCapabilities {
    await gate.run { () async -> DeviceCapabilities in
      disconnected ? [] : await device.capabilities()
    }
  }

  func storages() async throws(TransportError) -> [StorageInfo] {
    try await operation { () throws(TransportError) in try await refreshStorages() }
  }

  /// Reopens the device between operations, then reads its storages again, since their raw
  /// IDs are per connection. A device that cannot be opened again is gone.
  func forgetCachedItems() async throws(TransportError) {
    try await operation { () throws(TransportError) in
      await resolver.invalidateAll()
      try await device.reopen()
      rawStorages = [:]
      _ = try await refreshStorages()
    }
  }

  func close() async {
    await gate.run { () async in
      await resolver.invalidateAll()
      await device.close()
      await released()
    }
  }

  isolated deinit {
    // Dropped without `close()`: the device's own deinit releases the handle.
    if let onRelease { Task { await onRelease() } }
  }

  // MARK: Helpers

  private func released() async {
    guard let onRelease else { return }
    self.onRelease = nil
    await onRelease()
  }

  /// Runs `body` as one gated operation. A `.deviceDisconnected` from it releases the device,
  /// so later operations fail here instead of waiting on USB.
  func operation<T>(_ body: () async throws(TransportError) -> T)
    async throws(TransportError) -> T
  {
    try await gate.run { () async throws(TransportError) -> T in
      guard !disconnected else { throw .deviceDisconnected }
      do throws(TransportError) {
        return try await body()
      } catch {
        if error == .deviceDisconnected {
          disconnected = true
          await resolver.invalidateAll()
          await device.close()
          await released()
        }
        throw error
      }
    }
  }

  private func refreshStorages() async throws(TransportError) -> [StorageInfo] {
    let storages = try await device.storages()
    let keyed = Dictionary(
      storages.map { ($0.info.id.key, $0.raw) }, uniquingKeysWith: { first, _ in first })
    if keyed != rawStorages {
      rawStorages = keyed
      await resolver.invalidateAll()
    }
    return storages.map(\.info)
  }

  /// The raw ID of `storage`, re-reading the device's storages once if the key is unknown.
  func raw(_ storage: StorageID) async throws(TransportError) -> UInt32 {
    guard storage.device == info.id else { throw .storageNotFound(storage.key) }
    if let raw = rawStorages[storage.key] { return raw }
    _ = try await refreshStorages()
    guard let raw = rawStorages[storage.key] else { throw .storageNotFound(storage.key) }
    return raw
  }

  /// The object at `path`, which must not be the root, resolved from the cached listing of its
  /// folder when there is one, for a download: it changes nothing on the device, so a stale
  /// answer costs a retry, not data. The object is read again by its ID and used while it keeps
  /// its name, kind and folder; anything else lists the parent again.
  ///
  /// libmtp answers that read from the object info it loaded first, without asking the device,
  /// so it cannot see an object the device has since dropped or replaced. Only a listing, which
  /// reads the folder's object IDs from the device, can: so everything that changes the device,
  /// or decides whether to, resolves with `freshEntry`, and a download that fails lists again
  /// (see `relisted`).
  func entry(_ path: RemotePath, storage: UInt32) async throws(TransportError) -> MTPEntry {
    if let current = try await cachedAndConfirmed(path, storage: storage) { return current }
    return try await freshEntry(path, storage: storage)
  }

  /// The object at `path` with every folder from the root down to it listed again first: a
  /// cached ancestor could name a folder the device has since moved, and the object found
  /// through it would be somewhere else.
  func freshEntry(_ path: RemotePath, storage: UInt32) async throws(TransportError) -> MTPEntry {
    guard path.parent != nil else { throw .notFound(path) }
    await resolver.invalidate(.root, storage: storage)
    guard let entry = try await resolver.entry(at: path, storage: storage) else {
      throw .notFound(path)
    }
    return entry
  }

  /// The object the cached listing names at `path`, as the device reports it now; `nil` if no
  /// listing is cached, or the object is gone or is no longer that item. A lost device is still
  /// an error.
  private func cachedAndConfirmed(_ path: RemotePath, storage: UInt32)
    async throws(TransportError) -> MTPEntry?
  {
    guard let cached = await resolver.cachedEntry(at: path, storage: storage) else { return nil }
    let current: MTPEntry
    do {
      current = try await device.metadata(objectID: cached.objectID)
    } catch .deviceDisconnected {
      throw .deviceDisconnected
    } catch {
      return nil
    }
    let same =
      current.name.precomposedStringWithCanonicalMapping == path.name
      && current.isFolder == cached.isFolder && current.parent == cached.parent
    return same ? current : nil
  }

  /// The object at `path` with its folder listed again, after an operation on `stale`, the object
  /// the cache named, failed with `error`. If `path` now names another object or none, the device
  /// dropped or replaced `stale` since it was listed: `.notFound(path)` when `path` is gone, or
  /// the object now there. If it is still `stale`, the failure was real and `error` stands.
  func relisted(
    _ path: RemotePath, after error: TransportError, on stale: MTPEntry, storage: UInt32
  )
    async throws(TransportError) -> MTPEntry
  {
    guard error != .deviceDisconnected, error != .cancelled, let parent = path.parent else {
      throw error
    }
    await resolver.invalidate(parent, storage: storage)
    guard let current = try await resolver.entry(at: path, storage: storage),
      current.objectID != stale.objectID
    else { throw error }
    return current
  }

  /// The ID of the folder at `path` and its children, listed fresh from the device, from the
  /// root down: the children are what an existence check reads, and the folder is where a
  /// change lands. A missing path or a file is `.notFound`.
  func folder(_ path: RemotePath, storage: UInt32) async throws(TransportError)
    -> Folder
  {
    await resolver.invalidate(.root, storage: storage)
    let children = try await resolver.entries(in: path, storage: storage)
    let id = try await resolver.objectID(for: path, storage: storage)
    return Folder(id: id, children: children)
  }

  /// Runs `body`, then drops the cached listings of `folders` whether or not it succeeded.
  func mutating<T>(
    _ folders: [RemotePath], storage: UInt32, _ body: () async throws(TransportError) -> T
  ) async throws(TransportError) -> T {
    let result: Result<T, TransportError>
    do {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    for folder in folders {
      await resolver.invalidate(folder, storage: storage)
    }
    return try result.get()
  }

  /// The object `id` as the device now reports it, placed at `path`. If the device stored it
  /// under another name, it is not at `path`, so that is an error rather than a quiet success.
  /// `discardIfRenamed` deletes it first; only a fresh upload may be removed, since anything
  /// else is the user's data. Callers run inside `mutating`, which invalidates the folder.
  func stored(_ id: UInt32, at path: RemotePath, discardIfRenamed: Bool = false)
    async throws(TransportError) -> RemoteItem
  {
    let entry = try await device.metadata(objectID: id)
    let actual = entry.name.precomposedStringWithCanonicalMapping
    guard let requested = path.name, actual != requested else {
      return Self.item(entry, at: path)
    }
    if discardIfRenamed {
      do {
        try await device.delete(objectID: id)
      } catch {
        let reason = String(describing: error)
        Self.log.error(
          "could not delete renamed upload \(entry.name, privacy: .private): \(reason, privacy: .private)"
        )
      }
    }
    throw .nameChangedByDevice(requested: requested, actual: entry.name)
  }

  static func item(_ entry: MTPEntry, at path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, kind: entry.isFolder ? .folder : .file, size: entry.isFolder ? 0 : entry.size,
      modified: entry.modified)
  }

  static func split(_ path: RemotePath) throws(TransportError) -> (
    parent: RemotePath, name: String
  ) {
    guard let parent = path.parent, let name = path.name else {
      throw .invalidName(path.description)
    }
    return (parent, name)
  }

  struct Folder {
    let id: UInt32
    let children: [MTPEntry]

    /// Throws `.alreadyExists` naming the child that `path` collides with, other than `except`.
    /// Names collide without regard to case, since Android storage compares them that way.
    func requireFree(_ path: RemotePath, except: UInt32? = nil) throws(TransportError) {
      guard let parent = path.parent, let name = path.name else { return }
      let key = RemotePath.collisionKey(name)
      let taken = children.first {
        RemotePath.collisionKey($0.name) == key && $0.objectID != except
      }
      guard let taken else { return }
      throw .alreadyExists((try? parent.appending(taken.name)) ?? path)
    }
  }
}

// MARK: Reading

extension MTPSession {
  func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    try await operation { () throws(TransportError) in
      let raw = try await raw(storage)
      // MTP has no change events, so a listing re-reads the device; the cache serves resolution.
      await resolver.invalidate(folder, storage: raw)
      let entries = try await resolver.entries(in: folder, storage: raw)
      // MTP allows duplicate names; keep the one the resolver would pick, as the path names it.
      var byPath: [RemotePath: MTPEntry] = [:]
      for entry in entries {
        guard let path = try? folder.appending(entry.name) else {
          Self.log.error(
            "skipping object \(entry.objectID) with unusable name \(entry.name, privacy: .private)")
          continue
        }
        if let kept = byPath[path], kept.objectID < entry.objectID { continue }
        byPath[path] = entry
      }
      return byPath.map { Self.item($0.value, at: $0.key) }
        .sorted { $0.path.description < $1.path.description }
    }
  }

  func item(at path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      guard path != .root else {
        return RemoteItem(path: .root, kind: .folder, size: 0, modified: .distantPast)
      }
      // Fresh: a save's or a delete's base check reads it to decide whether to change the file.
      return Self.item(try await freshEntry(path, storage: raw(storage)), at: path)
    }
  }
}

// MARK: Writing

extension MTPSession {
  func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    try await operation { () throws(TransportError) in
      let (parent, name) = try Self.split(path)
      let raw = try await raw(storage)
      let target = try await folder(parent, storage: raw)
      try target.requireFree(path)
      return try await mutating([parent], storage: raw) { () throws(TransportError) in
        let id = try await device.upload(
          from: file, name: name, parent: target.id, storage: raw, progress: progress)
        return try await stored(id, at: path, discardIfRenamed: true)
      }
    }
  }

  func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      guard path != .root else { throw .alreadyExists(path) }
      let (parent, name) = try Self.split(path)
      let raw = try await raw(storage)
      let target = try await folder(parent, storage: raw)
      try target.requireFree(path)
      return try await mutating([parent], storage: raw) { () throws(TransportError) in
        let id = try await device.createFolder(name: name, parent: target.id, storage: raw)
        return try await stored(id, at: path)
      }
    }
  }

  func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      let (parent, _) = try Self.split(path)
      let renamed = try parent.appending(newName)
      let (_, name) = try Self.split(renamed)
      let raw = try await raw(storage)
      let siblings = try await folder(parent, storage: raw)
      // From the listing `folder` just read, so the device is listed once.
      guard let source = try await resolver.entry(at: path, storage: raw) else {
        throw .notFound(path)
      }
      try siblings.requireFree(renamed, except: source.objectID)
      return try await mutating([parent], storage: raw) { () throws(TransportError) in
        try await device.rename(objectID: source.objectID, to: name)
        return try await stored(source.objectID, at: renamed)
      }
    }
  }
}
