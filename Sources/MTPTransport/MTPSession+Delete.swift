import DeviceKit
import Foundation

// MARK: Deleting

extension MTPSession {
  /// Deletes the object the device, listed fresh, has at `path`, with all it holds. With
  /// `expecting`, only the objects the caller checked go (see `DeviceSession.delete`): the
  /// whole tree is read first, and anything else in it refuses the delete before any object
  /// goes. Once it is gone only it leaves the cached listing of its folder, which stays cached
  /// for downloads; a failure drops the listing.
  func delete(_ path: RemotePath, in storage: StorageID, expecting: [RemoteItem]?)
    async throws(TransportError)
  {
    try await operation { () throws(TransportError) in
      guard let parent = path.parent else { throw .notFound(path) }
      let raw = try await raw(storage)
      let entry = try await freshEntry(path, storage: raw)
      let checked = expecting.map { items in
        Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
      }
      if let checked {
        guard let top = checked[path], Self.item(entry, at: path).matches(top) else {
          throw .changedOnDevice(path)
        }
      }
      let doomed = try await tree(
        of: entry, at: path, depth: 0, DeleteWalk(top: path, checked: checked, storage: raw))
      do throws(TransportError) {
        for object in doomed {
          try await device.delete(objectID: object)
        }
      } catch {
        await resolver.invalidate(parent, storage: raw)
        throw error
      }
      await resolver.removed(entry.objectID, at: path, storage: raw)
    }
  }

  /// The object IDs of `entry` at `path` and everything in it, children before their folder, as
  /// MTP devices need not delete a non-empty folder. Children are listed fresh from the device.
  /// With `checked`, each item Finder would show must be one of those, as it was checked;
  /// anything else, including an item whose name Ferry cannot use (listings skip it, so Finder
  /// never saw it), is `.directoryNotEmpty(top)`. Partials and backups go with the folder.
  /// Past `RemotePath.maxTreeDepth` levels below `top` it is `.folderTooDeep(top)`, so a device
  /// that reports a loop cannot recurse without end. Nothing is deleted here.
  ///
  /// No object ID crosses `DeviceSession`, so a checked item is matched by path, kind, size and
  /// date (`RemoteItem.matches`). Two gaps follow: an object the device replaced with one of the
  /// same kind, size and date passes, and libmtp keeps the size and date it first read for an
  /// object, so a file an app rewrote in place keeping its object ID passes too.
  private func tree(of entry: MTPEntry, at path: RemotePath, depth: Int, _ walk: DeleteWalk)
    async throws(TransportError) -> [UInt32]
  {
    let (top, checked, storage) = (walk.top, walk.checked, walk.storage)
    guard depth <= RemotePath.maxTreeDepth else { throw .folderTooDeep(top) }
    var objects: [UInt32] = []
    if entry.isFolder {
      for child in try await device.list(storage: storage, parent: entry.objectID) {
        let childPath = try? path.appending(child.name)
        let hidden = SafeWriter.isPartial(child.name) || SafeWriter.isBackup(child.name)
        // An unusable name has no path to check what it holds against, hidden or not.
        guard childPath != nil || checked == nil else { throw .directoryNotEmpty(top) }
        if let checked, !hidden {
          guard let childPath, let seen = checked[childPath],
            Self.item(child, at: childPath).matches(seen)
          else { throw .directoryNotEmpty(top) }
        }
        // Unchecked, an unusable name's folder stands in for its path: only the depth is read.
        objects += try await tree(of: child, at: childPath ?? path, depth: depth + 1, walk)
      }
    }
    return objects + [entry.objectID]
  }

  /// What a delete's walk checks against: the folder deleted, what the caller checked, and the
  /// storage.
  private struct DeleteWalk {
    let top: RemotePath
    let checked: [RemotePath: RemoteItem]?
    let storage: UInt32
  }
}
