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

  /// Upload `file` to `path`. If `replacing`, an existing file at `path` is replaced;
  /// otherwise `.alreadyExists`.
  public func write(
    from file: URL, to path: RemotePath, in storage: StorageID, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    guard let parent = path.parent, let name = path.name else {
      throw .invalidName(path.description)
    }
    let size = try Self.localSize(of: file)

    // Reject before a byte moves when the storage is known to be too small.
    let storages = try await session.storages()
    if let free = storages.first(where: { $0.id == storage })?.free, size > free {
      throw .insufficientSpace(needed: size, free: free)
    }
    if !replacing, await exists(path, in: storage) {
      throw .alreadyExists(path)
    }

    let partial = try parent.appending(Self.partialPrefix + UUID().uuidString)
    await registry.register(storage, partial)
    do {
      let item = try await commit(
        Source(file: file, size: size), via: partial,
        to: Destination(path: path, name: name, replacing: replacing), in: storage,
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
    let replacing: Bool
  }

  // MARK: Steps

  private func commit(
    _ source: Source, via partial: RemotePath, to destination: Destination,
    in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let (file, size) = (source.file, source.size)
    try await upload(file, size: size, to: partial, in: storage, progress: progress)

    let path = destination.path
    if destination.replacing, await exists(path, in: storage) {
      do {
        try await session.delete(path, in: storage)
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
      return try await upload(file, size: size, to: path, in: storage, progress: progress)
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

  private func exists(_ path: RemotePath, in storage: StorageID) async -> Bool {
    (try? await session.item(at: path, in: storage)) != nil
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

  private static func localSize(of file: URL) throws(TransportError) -> UInt64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    } catch {
      throw .io(error.localizedDescription)
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
