import DeviceKit
import Foundation

/// Caches folder listings and resolves storage-relative paths to object IDs.
///
/// MTP addresses objects by ID only, so a path is resolved by listing each ancestor in turn.
/// Listings are cached per storage and folder until invalidated.
actor PathResolver {
  /// `LIBMTP_FILES_AND_FOLDERS_ROOT`: the parent ID that lists a storage's root.
  static let rootParent: UInt32 = 0xFFFF_FFFF

  typealias Lister =
    @Sendable (_ storage: UInt32, _ parent: UInt32) async throws(TransportError)
    -> [MTPEntry]

  private struct Key: Hashable {
    let storage: UInt32
    let folder: RemotePath
  }

  private let lister: Lister
  private var cache: [Key: [MTPEntry]] = [:]
  /// Bumped by every invalidation, so a listing that was in flight across one is not cached.
  private var generation = 0

  init(lister: @escaping Lister) {
    self.lister = lister
  }

  /// The object ID at `path`; the root resolves to `rootParent`.
  func objectID(for path: RemotePath, storage: UInt32) async throws(TransportError) -> UInt32 {
    try await entry(at: path, storage: storage)?.objectID ?? Self.rootParent
  }

  func entries(in folder: RemotePath, storage: UInt32) async throws(TransportError) -> [MTPEntry] {
    let key = Key(storage: storage, folder: folder)
    if let cached = cache[key] { return cached }

    // Sampled before resolving ancestors: an ID resolved before an invalidation may name an
    // object that has since moved, so neither it nor what it lists may be cached.
    let started = generation
    let id = try await folderID(for: folder, storage: storage)
    let listed = try await lister(storage, id)
    if generation == started {
      cache[key] = listed
    }
    return listed
  }

  /// Drops the listing of `folder` and of everything below it.
  func invalidate(_ folder: RemotePath, storage: UInt32) {
    generation += 1
    cache = cache.filter { key, _ in
      key.storage != storage || !key.folder.components.starts(with: folder.components)
    }
  }

  func invalidateAll() {
    generation += 1
    cache.removeAll()
  }

  /// The entry at `path`, or `nil` for the root.
  private func entry(at path: RemotePath, storage: UInt32) async throws(TransportError)
    -> MTPEntry?
  {
    guard let parent = path.parent, let name = path.name else { return nil }
    // A missing ancestor is reported as the requested path, not the ancestor.
    let siblings: [MTPEntry]
    do {
      siblings = try await entries(in: parent, storage: storage)
    } catch .notFound {
      throw .notFound(path)
    }
    // Duplicate names are legal on MTP; the lowest ID wins so resolution is stable.
    let match = siblings.filter { $0.name.precomposedStringWithCanonicalMapping == name }
      .min { $0.objectID < $1.objectID }
    guard let match else { throw .notFound(path) }
    return match
  }

  private func folderID(for folder: RemotePath, storage: UInt32) async throws(TransportError)
    -> UInt32
  {
    guard let entry = try await entry(at: folder, storage: storage) else {
      return Self.rootParent
    }
    guard entry.isFolder else { throw .notFound(folder) }
    return entry.objectID
  }
}
