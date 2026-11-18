import DeviceKit
import Foundation

// MARK: Deleting

extension ADBSession {
  /// Deletes what is at `path` with `rm`, a folder with all it holds (`rm -r`). With `expecting`,
  /// only what the caller checked goes (see `DeviceSession.delete`): the tree is listed fresh
  /// first, and anything else in it refuses the delete before anything goes.
  ///
  /// As with MTP, a checked item is matched by path, kind, size and date, so a file the device
  /// replaced with one of the same size and date passes, and something added between the check
  /// and `rm` goes with the folder.
  public func delete(_ path: RemotePath, in storage: StorageID, expecting: [RemoteItem]?)
    async throws(TransportError)
  {
    try await operation { () throws(TransportError) in
      guard path != .root else { throw .notFound(path) }
      let root = try await root(for: storage)
      guard let top = try await stat(path, under: root) else { throw .notFound(path) }
      if let expecting {
        let checked = Dictionary(
          expecting.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard let seen = checked[path], top.matches(seen) else { throw .changedOnDevice(path) }
        if top.kind == .folder {
          try await verify(path, depth: 0, DeleteWalk(top: path, checked: checked, root: root))
        }
      }
      let location = Self.devicePath(path, under: root)
      try await shell(
        "rm", top.kind == .folder ? ["-r", "--", location] : ["--", location], Step("delete", path))
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
