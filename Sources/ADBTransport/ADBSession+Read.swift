import DeviceKit
import Foundation

// MARK: Reading

extension ADBSession {
  public func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    try await operation { () throws(TransportError) in
      let root = try await root(for: storage)
      return try await children(of: folder, under: root).items
        .sorted { $0.path.description < $1.path.description }
    }
  }

  public func item(at path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    try await operation { () throws(TransportError) in
      let root = try await root(for: storage)
      guard path != .root else {
        return RemoteItem(path: .root, kind: .folder, size: 0, modified: .distantPast)
      }
      return try await existing(path, under: root).item
    }
  }

  static func item(_ stat: ADBStat, at path: RemotePath) -> RemoteItem? {
    if stat.isDirectory {
      return RemoteItem(path: path, kind: .folder, size: 0, modified: stat.mtime)
    }
    guard stat.isRegular else { return nil }
    return RemoteItem(path: path, kind: .file, size: stat.size, modified: stat.mtime)
  }

  static func split(_ path: RemotePath) throws(TransportError) -> (
    parent: RemotePath, name: String
  ) {
    guard let parent = path.parent, let name = path.name else {
      throw .invalidName(path.description)
    }
    return (parent, name)
  }

  /// Throws `.alreadyExists` naming the item `path` collides with, other than `except`. Names
  /// collide without regard to case, since Android storage compares them that way.
  static func requireFree(
    _ path: RemotePath, among items: [RemoteItem], except: RemotePath? = nil
  ) throws(TransportError) {
    let key = RemotePath.collisionKey(path.name ?? "")
    if let taken = items.first(where: {
      RemotePath.collisionKey($0.path.name ?? "") == key && $0.path != except
    }) {
      throw .alreadyExists(taken.path)
    }
  }
}

// MARK: Downloading

extension ADBSession {
  /// Downloads into a hidden partial beside `file` and renames it over `file` only once it is
  /// whole, as MTPSession does: a failed or short download leaves nothing at `file`. Whole means
  /// at least the size the device listed; more is the file grown since, and fewer is tried once
  /// more, then reported.
  @discardableResult
  public func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded {
    try await operation { () throws(TransportError) in
      let root = try await root(for: storage)
      var attempt = 1
      while true {
        let (listed, location) = try await existing(path, under: root)
        guard listed.kind == .file else { throw .notFound(path) }
        do throws(TransportError) {
          return try await downloadOnce(
            listed, from: location, to: file, replacing: replacing,
            progress: progress)
        } catch .downloadSizeMismatch(let listed, let received) {
          guard attempt < Self.downloadAttempts else {
            throw .downloadSizeMismatch(listed: listed, received: received)
          }
          Self.log.info("download cut short (\(received) of \(listed) bytes); trying again")
        }
        attempt += 1
      }
    }
  }

  private static let downloadAttempts = 2

  private func downloadOnce(
    _ listed: RemoteItem, from location: String, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded {
    try LocalFile.requireSpace(listed.size, at: file.deletingLastPathComponent())
    let partial = file.deletingLastPathComponent()
      .appendingPathComponent(SafeWriter.partialPrefix + UUID().uuidString)
    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
      throw .io("could not create \(partial.path)")
    }
    do throws(TransportError) {
      let received = try await receive(location, of: listed.path, into: partial, progress: progress)
      guard received >= listed.size else {
        throw .downloadSizeMismatch(listed: listed.size, received: received)
      }
      try LocalFile.place(partial, at: file, replacing: replacing, downloadOf: listed.path)
      return Downloaded(listed: listed, received: received)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }

  private func receive(
    _ location: String, of path: RemotePath, into partial: URL, progress: ProgressHandler
  ) async throws(TransportError) -> UInt64 {
    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: partial)
    } catch {
      throw .io("could not open \(partial.path): \(error.localizedDescription)")
    }
    defer { try? handle.close() }
    return try await adb(Step("download", path)) { () async throws(ADBError) in
      try await syncing { (sync) async throws(ADBError) in
        try await sync.receive(location, to: handle, progress: progress)
      }
    }
  }
}
