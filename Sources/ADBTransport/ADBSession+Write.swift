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
    try await operation(on: storage) { (root) throws(TransportError) in
      let (parent, _) = try Self.split(path)
      let siblings = try await children(of: parent, under: root, exactSizes: false)
      try Self.requireFree(path, among: siblings.items)
      let location = try await location(of: path, under: root)
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
      // The clash check compares names as Ferry does; the device may resolve another name to an
      // existing file (vfat ignores trailing dots, FAT has short names), and SEND would delete it.
      let taken = try await adb(Step("upload", path)) { () async throws(ADBError) in
        try await syncing { (sync) async throws(ADBError) in try await sync.stat(location) }
      }
      guard taken == nil else { throw .alreadyExists(path) }
      try await adb(Step("upload", path, target: path)) { () async throws(ADBError) in
        try await syncing { (sync) async throws(ADBError) in
          try await sync.send(
            handle, to: location, mode: Self.fileMode, mtime: modified, progress: progress)
        }
      }
      guard let item = try await stat(at: location, as: path), item.kind == .file else {
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
    try await operation(on: storage) { (root) throws(TransportError) in
      guard path != .root else { throw .alreadyExists(path) }
      let (parent, _) = try Self.split(path)
      let siblings = try await children(of: parent, under: root, exactSizes: false)
      try Self.requireFree(path, among: siblings.items)
      let location = try await location(of: path, under: root)
      try await shell("mkdir", ["--", location], Step("make folder", parent, target: path))
      guard let item = try await stat(at: location, as: path), item.kind == .folder else {
        throw .io("mkdir left no folder at \(path.description)")
      }
      return item
    }
  }

  public func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await operation(on: storage) { (root) throws(TransportError) in
      let (parent, name) = try Self.split(path)
      let renamed = try parent.appending(newName)
      let siblings = try await children(of: parent, under: root, exactSizes: false).items
      guard siblings.contains(where: { $0.path == path }) else { throw .notFound(path) }
      let source = try await location(of: path, under: root)
      guard renamed != path else {
        guard let item = try await stat(at: source, as: path) else { throw .notFound(path) }
        return item
      }
      try Self.requireFree(renamed, among: siblings, except: path)
      let folder = Self.parentLocation(source)
      let target = folder + "/" + (renamed.name ?? newName)
      defer { forget(folder) }
      forget(source)
      let step = Step("rename", path, target: renamed)
      if RemotePath.collisionKey(name) == RemotePath.collisionKey(newName) {
        try await renameCaseOnly(source, to: target, step)
      } else {
        try await mv(source, to: target, step)
      }
      guard let item = try await stat(at: target, as: renamed) else { throw .notFound(renamed) }
      return item
    }
  }

  /// Case-insensitive storage takes `mv a A` for a move onto itself: it does nothing and
  /// reports success, and for a folder it moves the folder into itself. So the item goes to a
  /// temporary name first. The name is visible, so an item stranded there by a lost device is
  /// found by the user rather than hidden or reaped.
  private func renameCaseOnly(_ source: String, to target: String, _ step: Step)
    async throws(TransportError)
  {
    let name = step.path.name ?? ""
    let tag = "-ferry-" + UUID().uuidString.prefix(8)
    let temporary =
      Self.parentLocation(source) + "/"
      + (RemotePath.fitsOnDevice(name + tag) ? name + tag : "ferry-" + UUID().uuidString)
    try await mv(source, to: temporary, step)
    do throws(TransportError) {
      try await mv(temporary, to: target, step)
    } catch {
      do throws(TransportError) {
        try await mv(temporary, to: source, step)
      } catch {
        Self.log.error(
          "\(step.path.description, privacy: .private) left at \(temporary, privacy: .private)")
      }
      throw error
    }
  }

  public func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await operation(on: storage) { (root) throws(TransportError) in
      let (_, name) = try Self.split(path)
      let source = try await existing(path, under: root).location
      let target = try toFolder.appending(name)
      let destination = try await children(of: toFolder, under: root, exactSizes: false)
      try Self.requireFree(target, among: destination.items)
      let folder = try await location(of: toFolder, under: root)
      // A move keeps the name as the device spells it.
      let moved = folder + "/" + Self.lastName(source)
      defer {
        forget(Self.parentLocation(source))
        forget(folder)
      }
      forget(source)
      try await mv(source, to: moved, Step("move", path, target: target))
      guard let item = try await stat(at: moved, as: target) else { throw .notFound(target) }
      return item
    }
  }

  /// `mv -n`, so an item that appeared at `target` since the check is never replaced. toybox
  /// then skips the move and still exits 0: a source still in place is that clash.
  ///
  /// Two races remain. toybox 0.7.4 has no `-T`, so a folder created at `target` between the
  /// check and the command receives the source inside it. And its overwrite prompt comes before
  /// `-n` is honoured: a file appearing at `target` with no write bits is unlinked when the
  /// prompt reads the closed stdin as yes (emulated storage gives files write bits, so this is
  /// for volumes with other filesystems).
  private func mv(_ source: String, to target: String, _ step: Step)
    async throws(TransportError)
  {
    try await shell("mv", ["-n", "--", source, target], step)
    if try await stat(at: source, as: step.path) != nil {
      throw .alreadyExists(step.target ?? step.path)
    }
  }
}
