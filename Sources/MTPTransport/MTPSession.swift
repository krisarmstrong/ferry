import DeviceKit
import Foundation
import os

/// A `DeviceSession` over one MTP device: turns storage-relative paths into object IDs and back.
///
/// Storages are addressed by `StorageID.key`; the raw MTP storage ID is a per-connection detail
/// that never leaves the session. Every mutation invalidates the cached listing of each folder it
/// touched, whether or not it succeeded, since a failed transfer can still leave an object behind.
actor MTPSession: DeviceSession {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "MTPSession")

  nonisolated let info: DeviceInfo
  private let device: any MTPDeviceOperations
  private let resolver: PathResolver
  /// Raw storage ID by `StorageID.key`, refreshed by `storages()`.
  private var rawStorages: [String: UInt32] = [:]

  init(device: any MTPDeviceOperations) {
    self.info = device.info
    self.device = device
    self.resolver = PathResolver { storage, parent throws(TransportError) in
      try await device.list(storage: storage, parent: parent)
    }
  }

  func capabilities() async -> DeviceCapabilities {
    await device.capabilities()
  }

  func storages() async throws(TransportError) -> [StorageInfo] {
    let storages = try await device.storages()
    let keyed = Dictionary(
      storages.map { ($0.info.id.key, $0.raw) }, uniquingKeysWith: { first, _ in first })
    if keyed != rawStorages {
      rawStorages = keyed
      await resolver.invalidateAll()
    }
    return storages.map(\.info)
  }

  func close() async {
    await resolver.invalidateAll()
    await device.close()
  }

  // MARK: Helpers

  /// The raw ID of `storage`, re-reading the device's storages once if the key is unknown.
  private func raw(_ storage: StorageID) async throws(TransportError) -> UInt32 {
    guard storage.device == info.id else { throw .notFound(.root) }
    if let raw = rawStorages[storage.key] { return raw }
    _ = try await storages()
    guard let raw = rawStorages[storage.key] else { throw .notFound(.root) }
    return raw
  }

  /// The object at `path`, which must not be the root.
  private func entry(_ path: RemotePath, storage: UInt32) async throws(TransportError) -> MTPEntry {
    guard let entry = try await resolver.entry(at: path, storage: storage) else {
      throw .notFound(path)
    }
    return entry
  }

  /// The ID of the folder at `path` and its children. A missing path or a file is `.notFound`.
  private func folder(_ path: RemotePath, storage: UInt32) async throws(TransportError)
    -> Folder
  {
    let children = try await resolver.entries(in: path, storage: storage)
    let id = try await resolver.objectID(for: path, storage: storage)
    return Folder(id: id, children: children)
  }

  /// Runs `body`, then drops the cached listings of `folders` whether or not it succeeded.
  private func mutating<T>(
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

  /// The object `id` as the device now reports it, placed at `path`.
  private func item(_ id: UInt32, at path: RemotePath) async throws(TransportError)
    -> RemoteItem
  {
    Self.item(try await device.metadata(objectID: id), at: path)
  }

  private static func item(_ entry: MTPEntry, at path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, kind: entry.isFolder ? .folder : .file, size: entry.isFolder ? 0 : entry.size,
      modified: entry.modified)
  }

  private static func split(_ path: RemotePath) throws(TransportError) -> (
    parent: RemotePath, name: String
  ) {
    guard let parent = path.parent, let name = path.name else {
      throw .invalidName(path.description)
    }
    return (parent, name)
  }

  private struct Folder {
    let id: UInt32
    let children: [MTPEntry]

    /// Throws `.alreadyExists(path)` if a child is named like `path`, other than `except`.
    func requireFree(_ path: RemotePath, except: UInt32? = nil) throws(TransportError) {
      let taken = children.contains {
        $0.name.precomposedStringWithCanonicalMapping == path.name && $0.objectID != except
      }
      if taken { throw .alreadyExists(path) }
    }
  }
}

// MARK: Reading

extension MTPSession {
  func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    let raw = try await raw(storage)
    let entries = try await resolver.entries(in: folder, storage: raw)
    // MTP allows duplicate names; keep the one the resolver would pick, as the path names it.
    var byPath: [RemotePath: MTPEntry] = [:]
    for entry in entries {
      guard let path = try? folder.appending(entry.name) else {
        Self.log.error(
          "skipping object \(entry.objectID) with unusable name \(entry.name, privacy: .public)")
        continue
      }
      if let kept = byPath[path], kept.objectID < entry.objectID { continue }
      byPath[path] = entry
    }
    return byPath.map { Self.item($0.value, at: $0.key) }
      .sorted { $0.path.description < $1.path.description }
  }

  func item(at path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    let raw = try await raw(storage)
    guard let entry = try await resolver.entry(at: path, storage: raw) else {
      return RemoteItem(path: .root, kind: .folder, size: 0, modified: .distantPast)
    }
    return Self.item(entry, at: path)
  }

  func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, progress: ProgressHandler
  ) async throws(TransportError) {
    let entry = try await entry(path, storage: raw(storage))
    guard !entry.isFolder else { throw .notFound(path) }
    try await device.download(objectID: entry.objectID, to: file, progress: progress)
  }
}

// MARK: Writing

extension MTPSession {
  func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let (parent, name) = try Self.split(path)
    let raw = try await raw(storage)
    let target = try await folder(parent, storage: raw)
    try target.requireFree(path)
    return try await mutating([parent], storage: raw) { () throws(TransportError) in
      let id = try await device.upload(
        from: file, name: name, parent: target.id, storage: raw, progress: progress)
      return try await item(id, at: path)
    }
  }

  func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    guard path != .root else { throw .alreadyExists(path) }
    let (parent, name) = try Self.split(path)
    let raw = try await raw(storage)
    let target = try await folder(parent, storage: raw)
    try target.requireFree(path)
    return try await mutating([parent], storage: raw) { () throws(TransportError) in
      let id = try await device.createFolder(name: name, parent: target.id, storage: raw)
      return try await item(id, at: path)
    }
  }

  func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    let (parent, _) = try Self.split(path)
    let renamed = try parent.appending(newName)
    let (_, name) = try Self.split(renamed)
    let raw = try await raw(storage)
    let source = try await entry(path, storage: raw)
    try await folder(parent, storage: raw).requireFree(renamed, except: source.objectID)
    return try await mutating([parent], storage: raw) { () throws(TransportError) in
      try await device.rename(objectID: source.objectID, to: name)
      return try await item(source.objectID, at: renamed)
    }
  }

  func delete(_ path: RemotePath, in storage: StorageID) async throws(TransportError) {
    guard let parent = path.parent else { throw .notFound(path) }
    let raw = try await raw(storage)
    let entry = try await entry(path, storage: raw)
    try await mutating([parent], storage: raw) { () throws(TransportError) in
      try await deleteTree(entry, storage: raw)
    }
  }

  /// Deletes `entry`, emptying a folder child by child first, since MTP devices need not delete
  /// a non-empty folder. Children are listed fresh from the device, not from the cache.
  private func deleteTree(_ entry: MTPEntry, storage: UInt32) async throws(TransportError) {
    if entry.isFolder {
      for child in try await device.list(storage: storage, parent: entry.objectID) {
        try await deleteTree(child, storage: storage)
      }
    }
    try await device.delete(objectID: entry.objectID)
  }
}

// MARK: Move

extension MTPSession {
  func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    let (parent, name) = try Self.split(path)
    let raw = try await raw(storage)
    let source = try await entry(path, storage: raw)
    let canMove = await device.capabilities().contains(.move)
    if !canMove, source.isFolder { throw .unsupported("move") }
    let destination = try await folder(toFolder, storage: raw)
    let target = try toFolder.appending(name)
    try destination.requireFree(target)

    guard canMove else {
      return try await copyThenDelete(
        source, from: parent,
        to: Placement(folder: toFolder, id: destination.id, target: target, name: name),
        storage: raw)
    }
    return try await mutating([parent, toFolder], storage: raw) { () throws(TransportError) in
      try await device.move(objectID: source.objectID, storage: raw, newParent: destination.id)
      return try await item(source.objectID, at: target)
    }
  }

  private struct Placement {
    let folder: RemotePath
    let id: UInt32
    let target: RemotePath
    let name: String
  }

  /// Move for a device without MoveObject. The copy goes up under a partial name and is renamed
  /// only once its size checks out, so a failure never leaves a short file under the real name;
  /// the source is deleted only after that.
  private func copyThenDelete(
    _ source: MTPEntry, from parent: RemotePath, to placement: Placement, storage: UInt32
  ) async throws(TransportError) -> RemoteItem {
    let local = FileManager.default.temporaryDirectory
      .appendingPathComponent("ferry-move-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: local) }
    try await device.download(objectID: source.objectID, to: local) { _, _ in true }

    let partialName = SafeWriter.partialPrefix + UUID().uuidString
    let copy: RemoteItem
    do {
      copy = try await mutating([placement.folder], storage: storage) {
        () throws(TransportError) in
        let id = try await device.upload(
          from: local, name: partialName, parent: placement.id, storage: storage
        ) { _, _ in true }
        let uploaded = try await device.metadata(objectID: id)
        guard uploaded.size == source.size else {
          throw .sizeMismatch(expected: source.size, actual: uploaded.size)
        }
        try await device.rename(objectID: id, to: placement.name)
        return try await item(id, at: placement.target)
      }
    } catch {
      await discard(partialName, in: placement.folder, storage: storage)
      throw error
    }

    try await mutating([parent], storage: storage) { () throws(TransportError) in
      try await device.delete(objectID: source.objectID)
    }
    return copy
  }

  /// Deletes `name` from `folder` if the device has it. Best effort: a failure is logged, and a
  /// partial left behind is reaped by the next `SafeWriter.visibleList` of that folder.
  private func discard(_ name: String, in folder: RemotePath, storage: UInt32) async {
    do {
      let path = try folder.appending(name)
      let entry = try await entry(path, storage: storage)
      try await mutating([folder], storage: storage) { () throws(TransportError) in
        try await device.delete(objectID: entry.objectID)
      }
    } catch .notFound {
      return
    } catch {
      Self.log.error(
        "could not delete partial \(name, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }
}
