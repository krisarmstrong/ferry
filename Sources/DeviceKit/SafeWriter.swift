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

  /// `.ferry-backup-<UUID>-<original name>`. The UUID has a fixed length, so the original name
  /// reads back unambiguously whatever it contains. A name too long for that is set aside under
  /// the UUID alone, and such a backup is never restored or deleted automatically.
  public static func backupName(for original: String) -> String {
    let unnamed = backupPrefix + UUID().uuidString
    let named = unnamed + "-" + original
    return named.utf8.count <= maxNameBytes ? named : unnamed
  }

  /// The name a backup was set aside from, or `nil` if it does not say.
  public static func originalName(ofBackup name: String) -> String? {
    guard isBackup(name) else { return nil }
    let rest = name.dropFirst(backupPrefix.count)
    let uuidLength = 36
    guard rest.count > uuidLength + 1, UUID(uuidString: String(rest.prefix(uuidLength))) != nil
    else { return nil }
    let tail = rest.dropFirst(uuidLength)
    guard tail.first == "-" else { return nil }
    return String(tail.dropFirst())
  }

  /// The longest name, in UTF-8 bytes, Android's storage takes.
  private static let maxNameBytes = 255

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
    guard let target = try await session.storages().first(where: { $0.id == storage }) else {
      throw .storageNotFound(storage.key)
    }
    if size > target.free {
      throw .insufficientSpace(needed: size, free: target.free)
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
        Source(file: file, size: size, onFAT: target.isFATLike), via: partial,
        to: Destination(path: path, name: name, replacing: existing), in: storage,
        progress: progress)
      await session.partials.unregisterInFlight(partial, in: storage)
      return item
    } catch {
      await session.partials.unregisterInFlight(partial, in: storage)
      throw error
    }
  }

  /// `list` that hides partials and backups. A partial no write holds is deleted. A backup from
  /// an earlier session, once no write is in flight in the folder, is resolved: see
  /// `resolveOrphan`. Clean-up is best effort, errors logged.
  public func visibleList(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    let items = try await session.list(folder, in: storage)
    let partials = session.partials
    var visible: [RemoteItem] = []
    var orphans: [RemoteItem] = []
    for item in items {
      let name = item.path.name ?? ""
      if Self.isPartial(name) {
        if await !partials.contains(item.path, in: storage) {
          await discard(item.path, in: storage)
        }
      } else if Self.isBackup(name) {
        let ours = await partials.isSessionBackup(item.path, in: storage)
        if !ours, await !partials.hasWriteInFlight(in: folder, storage: storage) {
          orphans.append(item)
        }
      } else {
        visible.append(item)
      }
    }
    for orphan in orphans {
      if let restored = await resolveOrphan(orphan, among: visible, in: storage) {
        visible.append(restored)
      }
    }
    return visible
  }

  /// A backup an earlier session left: the old file of a replace cut off before its end.
  ///
  /// If its original name is free, it is renamed back and returned: the replace never finished.
  /// If a complete file has the name, the replace did finish and only the backup's delete
  /// failed, so the backup is deleted once that file is read back as a file. Anything else (no
  /// readable name, a folder at the name) leaves it alone: a backup is never deleted blindly.
  private func resolveOrphan(
    _ backup: RemoteItem, among visible: [RemoteItem], in storage: StorageID
  )
    async -> RemoteItem?
  {
    guard let original = Self.originalName(ofBackup: backup.path.name ?? ""),
      let target = try? backup.path.parent?.appending(original)
    else {
      Self.log.error(
        "keeping a backup with no original name: \(backup.path.description, privacy: .private)")
      return nil
    }
    let key = RemotePath.collisionKey(original)
    guard let taken = visible.first(where: { RemotePath.collisionKey($0.path.name ?? "") == key })
    else {
      do {
        return try await session.rename(backup.path, to: original, in: storage)
      } catch {
        let reason = String(describing: error)
        Self.log.error(
          "could not restore \(target.description, privacy: .private): \(reason, privacy: .private)"
        )
        return nil
      }
    }
    guard taken.kind == .file,
      (try? await session.item(at: taken.path, in: storage))?.kind == .file
    else {
      Self.log.error("keeping a backup shadowed by \(taken.path.description, privacy: .private)")
      return nil
    }
    await discard(backup.path, in: storage)
    return nil
  }

  private struct Source {
    let file: URL
    let size: UInt64
    /// The storage it goes to is FAT-based (see `StorageInfo.isFATLike`).
    let onFAT: Bool
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
    try await upload(source, to: partial, in: storage, progress: progress)
    guard let replaced = destination.replacing else {
      do {
        return try await session.rename(partial, to: destination.name, in: storage)
      } catch {
        await discard(partial, in: storage)
        // Only a device that cannot rename gets the direct-upload fallback; anything else
        // (the name appeared, the device went away, a cancel, an I/O failure) surfaces.
        guard case .unsupported = error else { throw error }
        return try await upload(source, to: destination.path, in: storage, progress: progress)
      }
    }

    let backup: RemoteItem
    do {
      backup = try await session.rename(
        replaced.path, to: Self.backupName(for: replaced.path.name ?? destination.name),
        in: storage)
    } catch {
      await discard(partial, in: storage)
      if case .nameChangedByDevice(_, let actual) = error {
        // The device kept the old file under a name of its own choosing, which is neither the
        // user's name nor a hidden backup: it goes back to the user's name.
        if let stored = try? replaced.path.parent?.appending(actual) {
          await restore(stored, to: replaced.path, in: storage)
        }
        throw error
      }
      guard case .unsupported = error else { throw error }
      // No rename: nothing can be set aside, so the old file goes before a direct upload.
      try await session.delete(replaced.path, in: storage)
      return try await upload(source, to: destination.path, in: storage, progress: progress)
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
  /// logged: this session keeps it, and a later one renames it back (see `resolveOrphan`).
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
    _ source: Source, to target: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let (file, size, onFAT) = (source.file, source.size, source.onFAT)
    let item: RemoteItem
    do {
      item = try await session.upload(from: file, to: target, in: storage, progress: progress)
    } catch {
      // `.alreadyExists` means the object at `target` is not ours to delete.
      if case .alreadyExists = error {
        throw error
      }
      await discard(target, in: storage)
      // FAT's 4 GB limit is blamed only where the device says the storage is FAT: elsewhere
      // the device's own error says more than a guess would.
      if onFAT, size > UInt64(UInt32.max), case .io = error {
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
