import Foundation

// MARK: Folder trees

extension SafeWriter {
  /// Uploads the folder tree at `local` (folders and regular files; links left out) as the
  /// folder `path`, the way `write` uploads a file: the tree is built under a hidden partial
  /// name beside `path` and renamed into place only once complete. With `replacing`, a folder
  /// already at `path` is renamed aside to a backup name first, deleted only once the new tree
  /// has its name, and renamed back if it cannot; otherwise a folder there is `.alreadyExists`.
  /// A file is never replaced by a tree. A device that cannot rename gets the tree built in
  /// place, after the old one is deleted.
  public func writeTree(
    from local: URL, to path: RemotePath, in storage: StorageID, replacing: Bool
  ) async throws(TransportError) -> RemoteItem {
    guard let parent = path.parent, let name = path.name else {
      throw .invalidName(path.description)
    }
    let existing = try await existing(path, in: storage)
    if let existing, existing.kind == .file || !replacing {
      throw .alreadyExists(existing.path)
    }
    let partial = try parent.appending(Self.partialPrefix + UUID().uuidString)
    await session.partials.registerInFlight(partial, in: storage)
    let result: Result<RemoteItem, TransportError>
    do {
      result = .success(
        try await build(local, via: partial, as: name, replacing: existing, in: storage))
    } catch {
      result = .failure(error)
    }
    await session.partials.unregisterInFlight(partial, in: storage)
    return try result.get()
  }

  private func build(
    _ local: URL, via partial: RemotePath, as name: String, replacing existing: RemoteItem?,
    in storage: StorageID
  ) async throws(TransportError) -> RemoteItem {
    do {
      _ = try await session.makeFolder(partial, in: storage)
      try await uploadChildren(of: local, into: partial, in: storage)
    } catch {
      await discard(partial, in: storage)
      throw error
    }
    guard let existing else {
      do {
        return try await session.rename(partial, to: name, in: storage)
      } catch {
        await discard(partial, in: storage)
        guard case .unsupported = error, let path = try? partial.parent?.appending(name) else {
          throw error
        }
        return try await buildInPlace(local, at: path, in: storage)
      }
    }
    return try await swap(partial, for: existing, named: name, from: local, in: storage)
  }

  /// Puts the finished tree at `partial` in place of `old`: `old` is set aside, the tree takes
  /// the name, and only then is `old` deleted. If the tree cannot take the name, `old` returns.
  private func swap(
    _ partial: RemotePath, for old: RemoteItem, named name: String, from local: URL,
    in storage: StorageID
  ) async throws(TransportError) -> RemoteItem {
    let backup: RemoteItem
    do {
      backup = try await session.rename(
        old.path, to: Self.backupName(for: old.path.name ?? name), in: storage)
    } catch {
      await discard(partial, in: storage)
      guard case .unsupported = error else { throw error }
      try await session.delete(old.path, in: storage)
      return try await buildInPlace(local, at: old.path, in: storage)
    }
    await session.partials.recordBackup(backup.path, in: storage)
    let renamed: RemoteItem
    do {
      renamed = try await session.rename(partial, to: name, in: storage)
    } catch {
      await discard(partial, in: storage)
      await restore(backup.path, to: old.path, in: storage)
      throw error
    }
    await discard(backup.path, in: storage)
    return renamed
  }

  /// For a device that cannot rename: the tree is made at its real path directly.
  private func buildInPlace(_ local: URL, at path: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    let folder = try await session.makeFolder(path, in: storage)
    do {
      try await uploadChildren(of: local, into: path, in: storage)
    } catch {
      await discard(path, in: storage)
      throw error
    }
    return folder
  }

  /// Uploads what is inside `local` into the device folder `folder`, which is hidden or new, so
  /// nothing there needs setting aside. Each file is checked for its full size.
  private func uploadChildren(of local: URL, into folder: RemotePath, in storage: StorageID)
    async throws(TransportError)
  {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: local, includingPropertiesForKeys: keys
      ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      throw .io("reading \(local.lastPathComponent) failed: \(error.localizedDescription)")
    }
    for child in children {
      let values = try? child.resourceValues(forKeys: Set(keys))
      guard values?.isSymbolicLink != true else { continue }
      let target = try folder.appending(child.lastPathComponent)
      if values?.isDirectory == true {
        _ = try await session.makeFolder(target, in: storage)
        try await uploadChildren(of: child, into: target, in: storage)
      } else if values?.isRegularFile == true {
        let size = try LocalFile.regularFileSize(child)
        let item = try await session.upload(
          from: child, to: target, in: storage, progress: { _, _ in true })
        guard item.size == size else {
          throw .sizeMismatch(expected: size, actual: item.size)
        }
      }
    }
  }
}
