import DeviceKit
import Foundation

// MARK: Move

extension MTPSession {
  func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      let (parent, name) = try Self.split(path)
      let raw = try await raw(storage)
      let source = try await freshEntry(path, storage: raw)
      let canMove = await device.capabilities().contains(.move)
      if !canMove, source.isFolder { throw .unsupported("move") }
      let destination = try await folder(toFolder, storage: raw)
      let target = try toFolder.appending(name)
      try destination.requireFree(target)

      guard canMove else {
        return try await copyThenDelete(
          source, from: parent,
          to: Placement(
            storage: storage, folder: toFolder, id: destination.id, target: target, name: name),
          storage: raw)
      }
      return try await mutating([parent, toFolder], storage: raw) { () throws(TransportError) in
        try await device.move(objectID: source.objectID, storage: raw, newParent: destination.id)
        return try await stored(source.objectID, at: target)
      }
    }
  }

  private struct Placement {
    let storage: StorageID
    let folder: RemotePath
    let id: UInt32
    let target: RemotePath
    let name: String
  }

  /// Move for a device without MoveObject. The copy goes up under a partial name and is renamed
  /// only once its size checks out, so a failure never leaves a short file under the real name;
  /// the source is deleted only after that. The partial is registered in `partials` until it is
  /// renamed or discarded, so no `SafeWriter.visibleList` reaps it meanwhile. A copy can take
  /// as long as any transfer, so the request's cancel stops it at its next block, before the
  /// source is touched.
  private func copyThenDelete(
    _ source: MTPEntry, from parent: RemotePath, to placement: Placement, storage: UInt32
  ) async throws(TransportError) -> RemoteItem {
    let local = scratch.appendingPathComponent(LocalFile.moveScratchPrefix + UUID().uuidString)
    try LocalFile.requireSpace(source.size, at: local.deletingLastPathComponent())
    defer { try? FileManager.default.removeItem(at: local) }
    // libmtp reports progress on its own queue, where the request's task-local is not set.
    let (turn, heartbeat) = (DeviceTurns.current, TransferHeartbeat.current)
    let goOn: ProgressHandler = { _, _ in
      heartbeat?.beat()
      return turn?.isCancelled != true
    }
    try await device.download(objectID: source.objectID, to: local, progress: goOn)

    let partialName = SafeWriter.partialPrefix + UUID().uuidString
    let partial = try placement.folder.appending(partialName)
    await partials.registerInFlight(partial, in: placement.storage)
    let copy: RemoteItem
    do {
      copy = try await mutating([placement.folder], storage: storage) {
        () throws(TransportError) in
        let id = try await device.upload(
          from: local, name: partialName, parent: placement.id, storage: storage,
          progress: goOn)
        let uploaded = try await device.metadata(objectID: id)
        guard uploaded.size == source.size else {
          throw .sizeMismatch(expected: source.size, actual: uploaded.size)
        }
        try await device.rename(objectID: id, to: placement.name)
        return try await stored(id, at: placement.target)
      }
    } catch {
      await discard(partialName, in: placement.folder, storage: storage)
      await partials.unregisterInFlight(partial, in: placement.storage)
      throw error
    }
    await partials.unregisterInFlight(partial, in: placement.storage)

    // The copy is of the source as it was read. If an app on the device changed it meanwhile,
    // deleting it would lose the change: both stay, and the move fails saying so. libmtp shows
    // a change only to a new connection, so the device is reopened to look.
    let sourcePath = try parent.appending(source.name)
    try await reopenForFreshInfo()
    let raw = try await raw(placement.storage)
    let now = try? await freshEntry(sourcePath, storage: raw)
    guard let now, now.objectID == source.objectID, now.size == source.size,
      now.modified == source.modified
    else {
      throw .changedOnDevice(sourcePath)
    }
    try await mutating([parent], storage: raw) { () throws(TransportError) in
      try await device.delete(objectID: now.objectID)
    }
    return copy
  }

  /// Deletes `name` from `folder` if the device has it. Best effort: a failure is logged, and a
  /// partial left behind is reaped by the next `SafeWriter.visibleList` of that folder.
  private func discard(_ name: String, in folder: RemotePath, storage: UInt32) async {
    do {
      let path = try folder.appending(name)
      let entry = try await freshEntry(path, storage: storage)
      try await mutating([folder], storage: storage) { () throws(TransportError) in
        try await device.delete(objectID: entry.objectID)
      }
    } catch .notFound {
      return
    } catch {
      Self.log.error(
        "could not delete partial \(name, privacy: .private): \(String(describing: error), privacy: .private)"
      )
    }
  }
}
