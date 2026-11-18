import Foundation
import os

/// Guarantees a partial upload never appears under its real name: bytes land in a hidden
/// `.ferry-partial-*` object first and are renamed into place once complete.
///
/// A replace never deletes the old file before the new one is in place: the old file is renamed
/// to a hidden `.ferry-backup-*` name, the partial renamed into place, and only then the backup
/// deleted. If the partial cannot be renamed, the backup is renamed back. Only a device that
/// cannot rename at all gets a direct upload, and then the old file must go first.
///
/// Every `SafeWriter` over a session shares the session's registry, which is what keeps
/// `visibleList` from deleting a partial that a concurrent `write` is still uploading, or a
/// backup this session made. A listing removes a backup from an earlier session (one whose
/// delete failed, or whose write was cut off) once no write is in flight in its folder.
public struct SafeWriter: Sendable {
  public static let partialPrefix = ".ferry-partial-"

  public static func isPartial(_ name: String) -> Bool {
    name.hasPrefix(partialPrefix)
  }

  public static let backupPrefix = ".ferry-backup-"

  public static func isBackup(_ name: String) -> Bool {
    name.hasPrefix(backupPrefix)
  }

  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "SafeWriter")

  private let session: any DeviceSession

  public init(session: any DeviceSession) {
    self.session = session
  }

  /// Upload `file` to `path`. If `replacing`, an existing file at `path`, or one whose name
  /// differs only in case, is replaced; otherwise `.alreadyExists`. A folder is never replaced.
  public func write(
    from file: URL, to path: RemotePath, in storage: StorageID, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    guard let parent = path.parent, let name = path.name else {
      throw .invalidName(path.description)
    }
    let size = try LocalFile.regularFileSize(file)

    // Reject before a byte moves when the storage is gone or too small.
    guard let free = try await session.storages().first(where: { $0.id == storage })?.free else {
      throw .storageNotFound(storage.key)
    }
    if size > free {
      throw .insufficientSpace(needed: size, free: free)
    }
    // Read once, before the upload. `commit` sets aside whatever sits at that path when the
    // upload ends: an item swapped in during the upload is not detected.
    let existing = try await existing(path, in: storage)
    if let existing, existing.kind == .folder || !replacing {
      throw .alreadyExists(existing.path)
    }

    let partial = try parent.appending(Self.partialPrefix + UUID().uuidString)
    await session.partials.registerInFlight(partial, in: storage)
    do {
      let item = try await commit(
        Source(file: file, size: size), via: partial,
        to: Destination(path: path, name: name, replacing: existing), in: storage,
        progress: progress)
      await session.partials.unregisterInFlight(partial, in: storage)
      return item
    } catch {
      await session.partials.unregisterInFlight(partial, in: storage)
      throw error
    }
  }

  /// `list` that hides partials and backups, and deletes the abandoned ones (best effort, errors
  /// logged): a partial no write holds, and a backup from an earlier session once no write is in
  /// flight in the folder.
  public func visibleList(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    let items = try await session.list(folder, in: storage)
    let partials = session.partials
    var visible: [RemoteItem] = []
    for item in items {
      let name = item.path.name ?? ""
      if Self.isPartial(name) {
        if await !partials.contains(item.path, in: storage) {
          await discard(item.path, in: storage)
        }
      } else if Self.isBackup(name) {
        let ours = await partials.isSessionBackup(item.path, in: storage)
        if !ours, await !partials.hasWriteInFlight(in: folder, storage: storage) {
          await discard(item.path, in: storage)
        }
      } else {
        visible.append(item)
      }
    }
    return visible
  }

  private struct Source {
    let file: URL
    let size: UInt64
  }

  private struct Destination {
    let path: RemotePath
    let name: String
    /// The file this write replaces, set aside until the new one is in place.
    let replacing: RemoteItem?
  }

  // MARK: Steps

  private func commit(
    _ source: Source, via partial: RemotePath, to destination: Destination,
    in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let (file, size) = (source.file, source.size)
    try await upload(file, size: size, to: partial, in: storage, progress: progress)
    guard let replaced = destination.replacing else {
      do {
        return try await session.rename(partial, to: destination.name, in: storage)
      } catch {
        await discard(partial, in: storage)
        // Only a device that cannot rename gets the direct-upload fallback; anything else
        // (the name appeared, the device went away, a cancel, an I/O failure) surfaces.
        guard case .unsupported = error else { throw error }
        return try await upload(
          file, size: size, to: destination.path, in: storage, progress: progress)
      }
    }

    let backup: RemoteItem
    do {
      backup = try await session.rename(
        replaced.path, to: Self.backupPrefix + UUID().uuidString, in: storage)
    } catch {
      await discard(partial, in: storage)
      guard case .unsupported = error else { throw error }
      // No rename: nothing can be set aside, so the old file goes before a direct upload.
      try await session.delete(replaced.path, in: storage)
      return try await upload(
        file, size: size, to: destination.path, in: storage, progress: progress)
    }
    await session.partials.recordBackup(backup.path, in: storage)

    let renamed: RemoteItem
    do {
      renamed = try await session.rename(partial, to: destination.name, in: storage)
    } catch {
      await discard(partial, in: storage)
      await restore(backup.path, to: replaced.path, in: storage)
      throw error
    }
    await discard(backup.path, in: storage)
    return renamed
  }

  /// Renames a backup back to the file it was. If that fails the backup stays, hidden, and is
  /// logged: this session keeps it, a later one removes it.
  private func restore(_ backup: RemotePath, to original: RemotePath, in storage: StorageID)
    async
  {
    guard let name = original.name else { return }
    do {
      _ = try await session.rename(backup, to: name, in: storage)
    } catch {
      let reason = String(describing: error)
      Self.log.error(
        "could not restore \(original.description, privacy: .private) from its backup: \(reason, privacy: .private)"
      )
    }
  }

  /// Uploads to `target`, removing whatever the device kept if the transfer fails or comes up
  /// short. The original error is always the one thrown.
  @discardableResult
  private func upload(
    _ file: URL, size: UInt64, to target: RemotePath, in storage: StorageID,
    progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let item: RemoteItem
    do {
      item = try await session.upload(from: file, to: target, in: storage, progress: progress)
    } catch {
      // `.alreadyExists` means the object at `target` is not ours to delete.
      if case .alreadyExists = error {
        throw error
      }
      await discard(target, in: storage)
      if size > UInt64(UInt32.max), case .io = error {
        throw .fileTooLargeForStorage(size: size)
      }
      throw error
    }
    guard item.size == size else {
      await discard(target, in: storage)
      throw .sizeMismatch(expected: size, actual: item.size)
    }
    return item
  }

  /// The item `path` collides with, or `nil` if there is none: the exact name, else one that
  /// differs only in case, since Android storage compares names that way. A missing parent is
  /// `nil` too; the upload then reports it.
  ///
  /// Two or more colliding items are `.alreadyExists`, naming one that would not be replaced:
  /// the rename would meet it after the old file was set aside.
  private func existing(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem?
  {
    guard let parent = path.parent, let name = path.name else { return nil }
    let siblings: [RemoteItem]
    do {
      siblings = try await session.list(parent, in: storage)
    } catch .notFound {
      return nil
    }
    let key = RemotePath.collisionKey(name)
    let colliding = siblings.filter { RemotePath.collisionKey($0.path.name ?? "") == key }
    guard let chosen = colliding.first(where: { $0.path == path }) ?? colliding.first else {
      return nil
    }
    if let other = colliding.first(where: { $0.path != chosen.path }) {
      throw .alreadyExists(other.path)
    }
    return chosen
  }

  private func discard(_ path: RemotePath, in storage: StorageID) async {
    do {
      try await session.delete(path, in: storage)
    } catch .notFound {
      return
    } catch {
      let reason = String(describing: error)
      Self.log.error(
        "could not delete \(path.description, privacy: .private): \(reason, privacy: .private)"
      )
    }
  }
}

/// Partials still being written, and backups this session made, so a concurrent listing leaves
/// them alone. One per session; see `DeviceSession.partials`.
public actor PartialRegistry {
  private struct Entry: Hashable {
    let storage: StorageID
    let path: RemotePath
  }

  private var inFlight: Set<Entry> = []
  private var backups: Set<Entry> = []

  public init() {}

  public func registerInFlight(_ path: RemotePath, in storage: StorageID) {
    inFlight.insert(Entry(storage: storage, path: path))
  }

  public func unregisterInFlight(_ path: RemotePath, in storage: StorageID) {
    inFlight.remove(Entry(storage: storage, path: path))
  }

  public func contains(_ path: RemotePath, in storage: StorageID) -> Bool {
    inFlight.contains(Entry(storage: storage, path: path))
  }

  /// Whether a partial is being written in `folder`, so a replace there may be using a backup.
  public func hasWriteInFlight(in folder: RemotePath, storage: StorageID) -> Bool {
    inFlight.contains { $0.storage == storage && $0.path.parent == folder }
  }

  public func recordBackup(_ path: RemotePath, in storage: StorageID) {
    backups.insert(Entry(storage: storage, path: path))
  }

  /// Whether this session made the backup at `path`.
  public func isSessionBackup(_ path: RemotePath, in storage: StorageID) -> Bool {
    backups.contains(Entry(storage: storage, path: path))
  }
}
