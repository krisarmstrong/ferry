import DeviceKit
import Foundation

// MARK: Deleting

extension ADBSession {
  /// Deletes what is at `path` with `rm`, a folder with all it holds (`rm -r`). With `expecting`,
  /// only what the caller checked goes (see `DeviceSession.delete`): the tree is listed fresh
  /// first, and anything else in it refuses the delete before anything goes.
  ///
  /// A checked item is matched by path, kind, size and date, as with MTP, so a file the device
  /// replaced with one of the same size and date passes. Unlike MTP, which deletes by object ID,
  /// `rm` acts by path: a file another app replaces between the check and `rm` is deleted, and
  /// anything added to a checked folder meanwhile (the walk takes one STA2 per file) goes with
  /// it. Without `expecting` the tree is not walked, so `.folderTooDeep` never arises: `rm -r`
  /// bounds its own recursion, where MTPSession walks to delete object by object.
  public func delete(_ path: RemotePath, in storage: StorageID, expecting: [RemoteItem]?)
    async throws(TransportError)
  {
    try await operation(on: storage) { (root) throws(TransportError) in
      guard path != .root else { throw .notFound(path) }
      let (top, location) = try await existing(path, under: root)
      if let expecting {
        let checked = Dictionary(
          expecting.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard let seen = checked[path], top.matches(seen) else { throw .changedOnDevice(path) }
        if top.kind == .folder {
          try await verify(path, depth: 0, DeleteWalk(top: path, checked: checked, root: root))
        }
      }
      defer {
        forget(location)
        forget(Self.parentLocation(location))
      }
      let step = Step("delete", path)
      let result = try await run(
        "rm", top.kind == .folder ? ["-r", "--", location] : ["--", location], step)
      guard result.status != 0 else { return }
      let message = Self.message(of: result)
      // toybox names a child that failed by its own name, then says nothing of the folder. Only
      // a message wholly about the folder itself names why it remains; anything else is a tree
      // partly deleted.
      let aboutTop = message.hasPrefix("rm: \(location): ") && !message.contains("\n")
      guard top.kind == .file || aboutTop else {
        throw await reachable() ? .io("delete failed: \(message)") : .deviceDisconnected
      }
      throw await deviceFailure(message, step)
    }
  }

  /// Checks that everything Finder would show in `folder` is as the caller saw it. An entry the
  /// listing leaves out (Finder never saw it) is `.directoryNotEmpty(top)`, as is anything new
  /// or changed; partials and backups go unchecked, though what is inside them is checked. Past
  /// `RemotePath.maxTreeDepth` levels below `top` it is `.folderTooDeep(top)`.
  private func verify(_ folder: RemotePath, depth: Int, _ walk: DeleteWalk)
    async throws(TransportError)
  {
    let children = try await children(of: folder, under: walk.root)
    guard children.skipped == 0 else { throw .directoryNotEmpty(walk.top) }
    for child in children.items {
      guard depth + 1 <= RemotePath.maxTreeDepth else { throw .folderTooDeep(walk.top) }
      let name = child.path.name ?? ""
      if !SafeWriter.isPartial(name), !SafeWriter.isBackup(name) {
        guard let seen = walk.checked[child.path], child.matches(seen) else {
          throw .directoryNotEmpty(walk.top)
        }
      }
      if child.kind == .folder { try await verify(child.path, depth: depth + 1, walk) }
    }
  }

  private struct DeleteWalk {
    let top: RemotePath
    let checked: [RemotePath: RemoteItem]
    let root: String
  }
}
