import DeviceKit
import Foundation

/// In-memory device. Injected failures are one-shot: each applies to the next matching
/// operation and then clears itself.
public actor FakeDevice: DeviceSession {
  /// A call a test can hold mid-flight.
  public enum SuspendableCall: Sendable {
    case storages
    case close
  }

  private enum Suspension {
    case armed
    /// Armed, and a test is waiting for the call to arrive.
    case observed(CheckedContinuation<Void, Never>)
    case waiting(CheckedContinuation<Void, Never>)
  }

  private enum Node {
    case file(Data, modified: Date)
    case folder(modified: Date)
  }

  public nonisolated let info: DeviceInfo
  public nonisolated let partials = PartialRegistry()
  private let storageInfos: [StorageInfo]
  private let deviceCapabilities: DeviceCapabilities
  private var tree: [StorageID: [RemotePath: Node]]
  private var locked = false
  private var disconnected = false
  private var suspensions: [SuspendableCall: Suspension] = [:]
  private var uploadFailure: (afterBytes: UInt64, error: TransportError)?
  private var uploadTruncation: UInt64?
  private var renameFailure: TransportError?
  private var listFailure: TransportError?

  public init(
    info: DeviceInfo, storages: [StorageInfo],
    capabilities: DeviceCapabilities = [.move, .copy]
  ) {
    self.info = info
    self.storageInfos = storages
    self.deviceCapabilities = capabilities
    self.tree = Dictionary(uniqueKeysWithValues: storages.map { ($0.id, [:]) })
  }

  /// Opened by its transport and not closed since.
  public private(set) var isOpen = false
  public private(set) var closeCount = 0
  public private(set) var storagesCallCount = 0

  // MARK: DeviceSession

  public func capabilities() async -> DeviceCapabilities { deviceCapabilities }

  public func storages() async throws(TransportError) -> [StorageInfo] {
    storagesCallCount += 1
    await pauseIfSuspended(.storages)
    try requireAvailable()
    return storageInfos
  }

  public func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    if let failure = listFailure {
      listFailure = nil
      throw failure
    }
    let nodes = try nodes(in: storage)
    try requireFolder(folder, in: nodes)
    return nodes.filter { $0.key.parent == folder }
      .map { Self.item($0.key, $0.value) }
      .sorted { $0.path.description < $1.path.description }
  }

  public func item(at path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    let nodes = try nodes(in: storage)
    guard let node = path == .root ? .folder(modified: .distantPast) : nodes[path] else {
      throw .notFound(path)
    }
    return Self.item(path, node)
  }

  public func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) {
    let nodes = try nodes(in: storage)
    guard case .file(let data, _) = nodes[path] else { throw .notFound(path) }
    let total = UInt64(data.count)
    guard progress(0, total) else { throw .cancelled }
    do {
      try data.write(to: file, options: replacing ? [] : .withoutOverwriting)
    } catch CocoaError.fileWriteFileExists {
      throw .alreadyExists(path)
    } catch {
      throw .io(error.localizedDescription)
    }
    guard progress(total, total) else { throw .cancelled }
  }

  public func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    var nodes = try nodes(in: storage)
    guard let parent = path.parent else { throw .invalidName(path.description) }
    try requireFolder(parent, in: nodes)
    guard nodes[path] == nil else { throw .alreadyExists(path) }

    let failure = uploadFailure
    let limit = failure?.afterBytes ?? uploadTruncation
    let data = try Self.read(file, upTo: limit)
    let total = UInt64(data.count)
    guard progress(0, total) else { throw .cancelled }

    nodes[path] = .file(data, modified: Date())
    tree[storage] = nodes
    if let failure {
      uploadFailure = nil
      throw failure.error
    }
    guard progress(total, total) else {
      tree[storage]?[path] = nil
      throw .cancelled
    }
    return Self.item(path, .file(data, modified: Date()))
  }

  public func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    var nodes = try nodes(in: storage)
    guard let parent = path.parent else { throw .alreadyExists(path) }
    try requireFolder(parent, in: nodes)
    guard nodes[path] == nil else { throw .alreadyExists(path) }
    let node = Node.folder(modified: Date())
    nodes[path] = node
    tree[storage] = nodes
    return Self.item(path, node)
  }

  public func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    let nodes = try nodes(in: storage)
    if let failure = renameFailure {
      renameFailure = nil
      throw failure
    }
    guard let parent = path.parent else { throw .invalidName(path.description) }
    guard nodes[path] != nil else { throw .notFound(path) }
    return try relocate(path, to: parent.appending(newName), in: storage)
  }

  public func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    guard deviceCapabilities.contains(.move) else { throw .unsupported("move") }
    let nodes = try nodes(in: storage)
    guard let name = path.name else { throw .invalidName(path.description) }
    guard nodes[path] != nil else { throw .notFound(path) }
    try requireFolder(toFolder, in: nodes)
    return try relocate(path, to: toFolder.appending(name), in: storage)
  }

  public func delete(_ path: RemotePath, in storage: StorageID) async throws(TransportError) {
    var nodes = try nodes(in: storage)
    guard nodes[path] != nil else { throw .notFound(path) }
    for key in nodes.keys where Self.isSame(key, orInside: path) {
      nodes[key] = nil
    }
    tree[storage] = nodes
  }

  public func close() async {
    await pauseIfSuspended(.close)
    isOpen = false
    closeCount += 1
  }

  // MARK: Helpers

  private func requireAvailable() throws(TransportError) {
    if disconnected { throw .deviceDisconnected }
    if locked { throw .deviceLocked }
  }

  private func nodes(in storage: StorageID) throws(TransportError) -> [RemotePath: Node] {
    try requireAvailable()
    guard let nodes = tree[storage] else { throw .storageNotFound(storage.key) }
    return nodes
  }

  private func requireFolder(_ path: RemotePath, in nodes: [RemotePath: Node])
    throws(TransportError)
  {
    if path == .root { return }
    guard case .folder = nodes[path] else { throw .notFound(path) }
  }

  private func ensureFolders(_ path: RemotePath, in nodes: inout [RemotePath: Node])
    throws(TransportError)
  {
    var current = RemotePath.root
    for name in path.components {
      current = try current.appending(name)
      switch nodes[current] {
      case .none: nodes[current] = .folder(modified: Date())
      case .folder: break
      case .file: throw .alreadyExists(current)
      }
    }
  }

  /// Moves `source` and everything beneath it to `destination`.
  private func relocate(_ source: RemotePath, to destination: RemotePath, in storage: StorageID)
    throws(TransportError) -> RemoteItem
  {
    var nodes = try nodes(in: storage)
    guard nodes[destination] == nil else { throw .alreadyExists(destination) }
    let depth = source.components.count
    for key in nodes.keys where Self.isSame(key, orInside: source) {
      let moved = try RemotePath(
        (destination.components + key.components.dropFirst(depth)).map { "/" + $0 }.joined())
      nodes[moved] = nodes.removeValue(forKey: key)
    }
    tree[storage] = nodes
    guard let node = nodes[destination] else { throw .notFound(destination) }
    return Self.item(destination, node)
  }

  private static func isSame(_ path: RemotePath, orInside ancestor: RemotePath) -> Bool {
    path.components.starts(with: ancestor.components)
  }

  private static func item(_ path: RemotePath, _ node: Node) -> RemoteItem {
    switch node {
    case .file(let data, let modified):
      RemoteItem(path: path, kind: .file, size: UInt64(data.count), modified: modified)
    case .folder(let modified):
      RemoteItem(path: path, kind: .folder, size: 0, modified: modified)
    }
  }

  /// Reads the whole file, or at most `limit` bytes when a limit is given.
  private static func read(_ file: URL, upTo limit: UInt64?) throws(TransportError) -> Data {
    do {
      guard let limit else { return try Data(contentsOf: file) }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      return try handle.read(upToCount: Int(clamping: limit)) ?? Data()
    } catch {
      throw .io(error.localizedDescription)
    }
  }
}

// MARK: Test controls

extension FakeDevice {
  /// Creates missing parent folders and replaces an existing file at `path`.
  public func seed(_ path: RemotePath, in storage: StorageID, contents: Data)
    throws(TransportError)
  {
    guard let parent = path.parent else { throw .invalidName(path.description) }
    var nodes = try nodes(in: storage)
    try ensureFolders(parent, in: &nodes)
    if case .folder = nodes[path] { throw .alreadyExists(path) }
    nodes[path] = .file(contents, modified: Date())
    tree[storage] = nodes
  }

  public func setLocked(_ locked: Bool) {
    self.locked = locked
  }

  /// Every later call throws `.deviceDisconnected`, as from a device that was unplugged.
  public func setDisconnected() {
    disconnected = true
  }

  func markOpen() {
    isOpen = true
  }

  /// The next `call` waits until `resume(_:)`.
  public func suspendNext(_ call: SuspendableCall) {
    suspensions[call] = .armed
  }

  /// Returns once `call` is waiting on `suspendNext(_:)`.
  public func waitUntilSuspended(_ call: SuspendableCall) async {
    if case .waiting = suspensions[call] { return }
    await withCheckedContinuation { suspensions[call] = .observed($0) }
  }

  public func resume(_ call: SuspendableCall) {
    if case .waiting(let waiter) = suspensions[call] { waiter.resume() }
    suspensions[call] = nil
  }

  fileprivate func pauseIfSuspended(_ call: SuspendableCall) async {
    switch suspensions[call] {
    case nil, .waiting: break
    case .armed:
      await withCheckedContinuation { suspensions[call] = .waiting($0) }
    case .observed(let observer):
      await withCheckedContinuation {
        suspensions[call] = .waiting($0)
        observer.resume()
      }
    }
  }

  /// The next upload stores its first `afterBytes` bytes, then throws `error`.
  public func failUpload(afterBytes: UInt64, with error: TransportError) {
    uploadFailure = (afterBytes, error)
  }

  /// Uploads keep only the first `bytes` bytes and report success. `nil` turns this off.
  public func truncateUploads(to bytes: UInt64?) {
    uploadTruncation = bytes
  }

  /// The next rename throws `error`. `nil` clears a pending failure.
  public func failRename(with error: TransportError?) {
    renameFailure = error
  }

  /// The next `list(_:in:)` throws `error`. `nil` clears a pending failure.
  public func failList(with error: TransportError?) {
    listFailure = error
  }

  public func contents(of path: RemotePath, in storage: StorageID) -> Data? {
    if case .file(let data, _) = tree[storage]?[path] { return data }
    return nil
  }

  public func allPaths(in storage: StorageID) -> [RemotePath] {
    (tree[storage] ?? [:]).keys.sorted { $0.description < $1.description }
  }
}
