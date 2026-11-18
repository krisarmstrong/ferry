import DeviceKit
import Foundation

// MARK: Writing

extension ADBSession {
  /// Sends `file` to `path`, which must not exist: adbd would delete a file there before the
  /// first byte arrives, so the folder is listed fresh first. The device keeps the file's Mac
  /// modification date. A transfer that fails or is cancelled is removed by adbd itself.
  public func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    try await operation { () throws(TransportError) in
      let (parent, _) = try Self.split(path)
      let root = try await root(for: storage)
      try Self.requireFree(path, among: try await children(of: parent, under: root).items)
      let modified =
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? Date()
      let handle: FileHandle
      do {
        handle = try FileHandle(forReadingFrom: file)
      } catch {
        throw .io("could not open \(file.path): \(error.localizedDescription)")
      }
      defer { try? handle.close() }
      let location = Self.devicePath(path, under: root)
      try await adb(Step("upload", path, target: path)) { () async throws(ADBError) in
        try await syncing { (sync) async throws(ADBError) in
          try await sync.send(
            handle, to: location, mode: Self.fileMode, mtime: modified, progress: progress)
        }
      }
      guard let item = try await stat(path, under: root), item.kind == .file else {
        throw .io("upload of \(path.description) left no file")
      }
      return item
    }
  }

  /// A regular file, read and write for its owner; the storage applies its own permissions.
  private static let fileMode: UInt32 = 0o100644

  public func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      guard path != .root else { throw .alreadyExists(path) }
      let (parent, _) = try Self.split(path)
      let root = try await root(for: storage)
      try Self.requireFree(path, among: try await children(of: parent, under: root).items)
      try await shell(
        "mkdir", ["--", Self.devicePath(path, under: root)],
        Step("make folder", parent, target: path))
      guard let item = try await stat(path, under: root), item.kind == .folder else {
        throw .io("mkdir left no folder at \(path.description)")
      }
      return item
    }
  }

  public func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      let (parent, name) = try Self.split(path)
      let renamed = try parent.appending(newName)
      let root = try await root(for: storage)
      let siblings = try await children(of: parent, under: root).items
      guard let source = siblings.first(where: { $0.path == path }) else { throw .notFound(path) }
      guard renamed != path else { return source }
      try Self.requireFree(renamed, among: siblings, except: path)
      if RemotePath.collisionKey(name) == RemotePath.collisionKey(newName) {
        try await renameCaseOnly(path, to: renamed, under: root)
      } else {
        try await mv(path, to: renamed, under: root, step: "rename")
      }
      guard let item = try await stat(renamed, under: root) else { throw .notFound(renamed) }
      return item
    }
  }

  /// Case-insensitive storage takes `mv a A` for a move onto itself: it does nothing and
  /// reports success, and for a folder it moves the folder into itself. So the item goes to a
  /// temporary name first. The name is visible, so an item stranded there by a lost device is
  /// found by the user rather than hidden or reaped.
  private func renameCaseOnly(_ path: RemotePath, to renamed: RemotePath, under root: String)
    async throws(TransportError)
  {
    let (parent, name) = try Self.split(path)
    let tag = "-ferry-" + UUID().uuidString.prefix(8)
    let temporary = try parent.appending(
      RemotePath.fitsOnDevice(name + tag) ? name + tag : "ferry-" + UUID().uuidString)
    try await mv(path, to: temporary, under: root, step: "rename")
    do throws(TransportError) {
      try await mv(temporary, to: renamed, under: root, step: "rename")
    } catch {
      do throws(TransportError) {
        try await mv(temporary, to: path, under: root, step: "rename")
      } catch {
        Self.log.error(
          "\(path.description, privacy: .private) left at \(temporary.description, privacy: .private)"
        )
      }
      throw error
    }
  }

  public func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      let (_, name) = try Self.split(path)
      let root = try await root(for: storage)
      guard try await stat(path, under: root) != nil else { throw .notFound(path) }
      let target = try toFolder.appending(name)
      try Self.requireFree(target, among: try await children(of: toFolder, under: root).items)
      try await mv(path, to: target, under: root, step: "move")
      guard let item = try await stat(target, under: root) else { throw .notFound(target) }
      return item
    }
  }

  /// `mv -n`, so an item that appeared at `target` since the check is never replaced. toybox
  /// then skips the move and still exits 0: a source still in place is that clash.
  ///
  /// One race remains: toybox has no `-T`, so a folder created at `target` between the check
  /// and the command receives the source inside it.
  private func mv(_ source: RemotePath, to target: RemotePath, under root: String, step: String)
    async throws(TransportError)
  {
    try await shell(
      "mv",
      ["-n", "--", Self.devicePath(source, under: root), Self.devicePath(target, under: root)],
      Step(step, source, target: target))
    if try await stat(source, under: root) != nil { throw .alreadyExists(target) }
  }
}
