import DeviceKit
import Foundation

// MARK: Deleting

extension MTPSession {
  /// Deletes the object the folder, listed fresh, has at `path`. Once it is gone only it leaves
  /// that listing, which stays cached for downloads; a failure drops the listing.
  func delete(_ path: RemotePath, in storage: StorageID) async throws(TransportError) {
    try await operation { () throws(TransportError) in
      guard let parent = path.parent else { throw .notFound(path) }
      let raw = try await raw(storage)
      let entry = try await freshEntry(path, storage: raw)
      do throws(TransportError) {
        try await deleteTree(entry, at: path, depth: 0, storage: raw)
      } catch {
        await resolver.invalidate(parent, storage: raw)
        throw error
      }
      await resolver.removed(entry.objectID, at: path, storage: raw)
    }
  }

  /// Deletes `entry`, `depth` levels below `top`, emptying a folder child by child first, since
  /// MTP devices need not delete a non-empty folder. Children are listed fresh from the device,
  /// not from the cache. Past `RemotePath.maxTreeDepth` levels it stops with `.folderTooDeep`,
  /// so a device that reports a loop cannot recurse without end; what it deleted on the way
  /// down stays deleted. (The agent walks a tree before it deletes it, and refuses one that deep
  /// before anything goes.)
  private func deleteTree(_ entry: MTPEntry, at top: RemotePath, depth: Int, storage: UInt32)
    async throws(TransportError)
  {
    guard depth <= RemotePath.maxTreeDepth else { throw .folderTooDeep(top) }
    if entry.isFolder {
      for child in try await device.list(storage: storage, parent: entry.objectID) {
        try await deleteTree(child, at: top, depth: depth + 1, storage: storage)
      }
    }
    try await device.delete(objectID: entry.objectID)
  }
}
