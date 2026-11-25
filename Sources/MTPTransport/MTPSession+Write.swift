import DeviceKit
import Foundation

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
        let item = try await stored(id, at: path, discardIfRenamed: true)
        try await recordInWrite(id, at: path, storage: raw)
        return item
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
      // Only an object the write made is known to its listing; for others, list afresh.
      if !Self.isOwnedByWrite(path, raw) {
        WriteListing.current?.forget(Self.listingKey(parent, raw))
      }
      let siblings = try await folder(parent, storage: raw)
      // From the listing `folder` just read (or the write's), so the device is listed once.
      guard let source = try await resolver.entry(at: path, storage: raw) else {
        throw .notFound(path)
      }
      try siblings.requireFree(renamed, except: source.objectID)
      return try await mutating([parent], storage: raw) { () throws(TransportError) in
        try await device.rename(objectID: source.objectID, to: name)
        let item = try await stored(source.objectID, at: renamed)
        try await recordInWrite(source.objectID, at: renamed, storage: raw)
        return item
      }
    }
  }
}
