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
      let doomed = try await tree(of: entry, at: path, top: path, checked: checked, storage: raw)
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
  /// anything else is `.directoryNotEmpty(top)`. Partials and backups go with the folder.
  /// Past `RemotePath.maxTreeDepth` levels below `top` it is `.folderTooDeep(top)`, so a device
  /// that reports a loop cannot recurse without end. Nothing is deleted here.
  private func tree(
    of entry: MTPEntry, at path: RemotePath, top: RemotePath, checked: [RemotePath: RemoteItem]?,
    storage: UInt32
  ) async throws(TransportError) -> [UInt32] {
    let depth = path.components.count - top.components.count
    guard depth <= RemotePath.maxTreeDepth else { throw .folderTooDeep(top) }
    var objects: [UInt32] = []
    if entry.isFolder {
      for child in try await device.list(storage: storage, parent: entry.objectID) {
        let childPath = try path.appending(child.name)
        let hidden = SafeWriter.isPartial(child.name) || SafeWriter.isBackup(child.name)
        if let checked, !hidden {
          guard let seen = checked[childPath], Self.item(child, at: childPath).matches(seen) else {
            throw .directoryNotEmpty(top)
          }
        }
        objects += try await tree(
          of: child, at: childPath, top: top, checked: checked, storage: storage)
      }
    }
    return objects + [entry.objectID]
  }
}
