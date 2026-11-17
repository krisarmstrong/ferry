import Foundation
import os

/// Guarantees a partial upload never appears under its real name: bytes land in a hidden
/// `.ferry-partial-*` object first and are renamed into place once complete.
///
/// Use one `SafeWriter` per session. Copies share one in-flight registry, which is what keeps
/// `visibleList` from deleting a partial that a concurrent `write` is still uploading.
public struct SafeWriter: Sendable {
  public static let partialPrefix = ".ferry-partial-"

  public static func isPartial(_ name: String) -> Bool {
    name.hasPrefix(partialPrefix)
  }

  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "SafeWriter")

  private let session: any DeviceSession
  let registry: PartialRegistry

  public init(session: any DeviceSession) {
    self.session = session
    self.registry = PartialRegistry()
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
    // Read once, before the upload. `commit` deletes by path, so whatever sits at that path when
    // the upload ends is deleted: an item swapped in during the upload is not detected.
    let existing = try await existing(path, in: storage)
    if let existing, existing.kind == .folder || !replacing {
      throw .alreadyExists(existing.path)
    }

    let partial = try parent.appending(Self.partialPrefix + UUID().uuidString)
    await registry.register(storage, partial)
    do {
      let item = try await commit(
        Source(file: file, size: size), via: partial,
        to: Destination(path: path, name: name, replacing: existing), in: storage,
        progress: progress)
      await registry.unregister(storage, partial)
      return item
    } catch {
      await registry.unregister(storage, partial)
      throw error
    }
  }

  /// `list` that hides partials and deletes the abandoned ones (best effort, errors logged).
  public func visibleList(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    let items = try await session.list(folder, in: storage)
    var visible: [RemoteItem] = []
    for item in items {
      guard Self.isPartial(item.path.name ?? "") else {
        visible.append(item)
        continue
      }
      if await !registry.contains(storage, item.path) {
        await discard(item.path, in: storage)
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
    /// The file this write replaces, deleted just before the rename.
    let replacing: RemoteItem?
  }

  // MARK: Steps

  private func commit(
    _ source: Source, via partial: RemotePath, to destination: Destination,
    in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let (file, size) = (source.file, source.size)
    try await upload(file, size: size, to: partial, in: storage, progress: progress)

    if let replaced = destination.replacing {
      do {
        try await session.delete(replaced.path, in: storage)
      } catch {
        await discard(partial, in: storage)
        throw error
      }
    }

    let renamed: RemoteItem
    do {
      renamed = try await session.rename(partial, to: destination.name, in: storage)
    } catch {
      await discard(partial, in: storage)
      // Only a device that cannot rename gets the direct-upload fallback; anything else
      // (the name appeared, the device went away, a cancel) must surface unchanged.
      switch error {
      case .unsupported, .io:
        return try await upload(
          file, size: size, to: destination.path, in: storage, progress: progress)
      default:
        throw error
      }
    }
    return renamed
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
  /// the rename would meet it after the delete, losing both the old file and the new one.
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
      Self.log.error(
        "could not delete partial \(path.description, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }
}

/// Partials a `write` is still uploading, so a concurrent listing leaves them alone.
actor PartialRegistry {
  private struct Entry: Hashable {
    let storage: StorageID
    let path: RemotePath
  }

  private var inFlight: Set<Entry> = []

  func register(_ storage: StorageID, _ path: RemotePath) {
    inFlight.insert(Entry(storage: storage, path: path))
  }

  func unregister(_ storage: StorageID, _ path: RemotePath) {
    inFlight.remove(Entry(storage: storage, path: path))
  }

  func contains(_ storage: StorageID, _ path: RemotePath) -> Bool {
    inFlight.contains(Entry(storage: storage, path: path))
  }
}
