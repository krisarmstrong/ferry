import Foundation
import os

// MARK: Replacing on a device that cannot rename

extension SafeWriter {
  /// Replaces `replaced` on a device that cannot rename, so the old file must go before the new
  /// one can take its name. The old file is first copied to `backups` and checked; only then is
  /// it deleted and the new one uploaded. If the upload fails the original is uploaded again and
  /// checked, and the backup removed once the device holds it. A backup that cannot be made
  /// refuses the replace before anything on the device changes. One that cannot be put back
  /// stays on the Mac until a later listing of its folder does it (see `settleLocalBackup`).
  func replaceWithoutRename(
    _ source: Source, replacing replaced: RemoteItem, in storage: StorageID,
    progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    let backup = try await backUp(replaced, for: source, in: storage, progress: progress)
    let id = backup.manifest.id
    let partials = session.partials
    _ = await partials.claimLocalBackup(id)
    do {
      try await session.delete(replaced.path, in: storage, expecting: [replaced])
    } catch {
      // A delete can fail after it took effect (its reply lost with the device): the backup goes
      // only if the original is plainly still there.
      let still = try? await session.item(at: replaced.path, in: storage)
      if still?.matches(replaced) == true { backups.remove(id) }
      await partials.releaseLocalBackup(id)
      throw error
    }
    do {
      let item = try await upload(source, to: replaced.path, in: storage, progress: progress)
      backups.remove(id)
      await partials.releaseLocalBackup(id)
      return item
    } catch {
      if let restored = await putBack(backup, in: storage) {
        await partials.recordRestore(restored, of: replaced, in: storage)
      }
      await partials.releaseLocalBackup(id)
      throw error
    }
  }

  /// Copies `replaced` into a new backup, with a clone of the new contents so a later session
  /// can recognise an upload of them cut short. Honours a cancel; reports no progress of its own,
  /// since nothing has gone to the device yet.
  private func backUp(
    _ replaced: RemoteItem, for source: Source, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> ReplaceBackups.Backup {
    let (id, file) = try backups.newDataFile()
    do throws(TransportError) {
      try LocalFile.requireSpace(replaced.size + source.size, at: backups.folder)
      let total = source.size
      let downloaded = try await session.download(
        replaced.path, in: storage, to: file, replacing: false,
        progress: { _, _ in progress(0, total) })
      // The bytes must be the file the write was checked against, not one swapped in since.
      guard downloaded.listed.matches(replaced) else {
        throw TransportError.changedOnDevice(replaced.path)
      }
      try backups.keepNewContents(source.file, for: id)
      return try backups.commit(
        ReplaceBackups.Manifest(
          id: id, storage: storage, path: replaced.path, size: downloaded.received,
          sha256: try LocalFile.sha256(file), newSize: source.size,
          newSHA256: try LocalFile.sha256(source.file)))
    } catch {
      backups.remove(id)
      throw error
    }
  }

  /// Uploads the backup to its path and checks the device holds it whole: by size, and by
  /// SHA-256 when the file can be read back. Returns the file, the backup removed; `nil` when
  /// the device does not hold it, the backup then kept for a later listing.
  func putBack(_ backup: ReplaceBackups.Backup, in storage: StorageID) async -> RemoteItem? {
    let manifest = backup.manifest
    let item: RemoteItem
    do {
      // Not the caller's transfer: a cancelled replace must still get its original back.
      item = try await upload(
        Source(file: backup.data, size: manifest.size, onFAT: false), to: manifest.path,
        in: storage, progress: { _, _ in true })
    } catch {
      let reason = String(describing: error)
      Self.log.error(
        "could not put back \(manifest.path.description, privacy: .private): \(reason, privacy: .private)"
      )
      return nil
    }
    if let read = await readBack(item.path, in: storage) {
      try? FileManager.default.removeItem(at: read.file)
      if read.sha256 != manifest.sha256 {
        Self.log.error("\(manifest.path.description, privacy: .private) came back altered")
        await discard(item.path, in: storage)
        return nil
      }
    }
    backups.remove(manifest.id)
    return item
  }

  /// A backup an earlier write left in this folder: its replace failed and the original could
  /// not be put back, or the device went away before the backup was removed.
  ///
  /// If the name is free the original goes back. If the name holds the original or the new
  /// contents, the replace was settled and the backup goes. If it holds the start of the new
  /// contents (an upload the device lost mid-way), that copy is deleted and the original goes
  /// back. Anything else is someone else's file: the backup is kept and nothing is overwritten.
  func settleLocalBackup(
    _ backup: ReplaceBackups.Backup, among visible: [RemoteItem], in storage: StorageID
  ) async -> RemoteItem? {
    let partials = session.partials
    let id = backup.manifest.id
    guard await partials.claimLocalBackup(id) else { return nil }
    let restored = await settle(backup, among: visible, in: storage)
    await partials.releaseLocalBackup(id)
    return restored
  }

  private func settle(
    _ backup: ReplaceBackups.Backup, among visible: [RemoteItem], in storage: StorageID
  ) async -> RemoteItem? {
    let manifest = backup.manifest
    let key = RemotePath.collisionKey(manifest.path.name ?? "")
    guard let taken = visible.first(where: { RemotePath.collisionKey($0.path.name ?? "") == key })
    else {
      return await putBack(backup, in: storage)
    }
    // A file whose contents cannot be read now is tried again at the next listing.
    guard taken.kind == .file, taken.path == manifest.path,
      let read = await readBack(taken.path, in: storage)
    else {
      if taken.kind == .folder || taken.path != manifest.path {
        await keep(backup, shadowedBy: taken)
      }
      return nil
    }
    defer { try? FileManager.default.removeItem(at: read.file) }
    if read.sha256 == manifest.sha256 || read.sha256 == manifest.newSHA256 {
      backups.remove(manifest.id)
      return nil
    }
    guard backups.isStartOfNewContents(read.file, for: manifest.id) else {
      await keep(backup, shadowedBy: taken)
      return nil
    }
    do {
      try await session.delete(taken.path, in: storage, expecting: [taken])
    } catch {
      return nil
    }
    return await putBack(backup, in: storage)
  }

  /// Leaves the backup alone for the rest of the session, so later listings do not read the
  /// file at its name again.
  private func keep(_ backup: ReplaceBackups.Backup, shadowedBy taken: RemoteItem) async {
    let (original, holder) = (backup.manifest.path.description, taken.path.description)
    Self.log.error(
      "keeping the backup of \(original, privacy: .private): its name holds \(holder, privacy: .private)"
    )
    await session.partials.keepLocalBackup(backup.manifest.id)
  }

  /// The device's file at `path` read into a scratch file, with its SHA-256; `nil` if it cannot
  /// be read. The caller removes the file.
  private func readBack(_ path: RemotePath, in storage: StorageID) async -> (
    file: URL, sha256: String
  )? {
    let file = backups.scratchFile()
    do {
      _ = try await session.download(
        path, in: storage, to: file, replacing: false, progress: { _, _ in true })
      return (file, try LocalFile.sha256(file))
    } catch {
      try? FileManager.default.removeItem(at: file)
      return nil
    }
  }
}
