import DeviceKit
import Foundation

/// In-memory device. Injected failures are one-shot: each applies to the next matching
/// operation and then clears itself.
public actor FakeDevice: DeviceSession {
  /// A call a test can hold mid-flight.
  public enum SuspendableCall: Sendable {
    case storages
    case list
    case close
  }

  private enum Suspension {
    case armed
    /// Armed, and a test is waiting for the call to arrive.
    case observed(CheckedContinuation<Void, Never>)
    case waiting(CheckedContinuation<Void, Never>)
  }

  enum Node {
    case file(Data, modified: Date)
    case folder(modified: Date)
  }

  public nonisolated let info: DeviceInfo
  public nonisolated let partials = PartialRegistry()
  /// How the transport that opened it reaches it.
  public internal(set) var method = ConnectionMethod.usbFileTransfer
  var storageInfos: [StorageInfo]
  let deviceCapabilities: DeviceCapabilities
  var tree: [StorageID: [RemotePath: Node]]
  private var locked = false
  private var disconnected = false
  private var suspensions: [SuspendableCall: Suspension] = [:]
  var uploadFailure: (afterBytes: UInt64, error: TransportError)?
  var uploadTruncation: UInt64?
  var renameFailure: RenameFailure?
  /// Sizes listed for files instead of their real ones, as a device's stale metadata does.
  var reportedSizes: [RemotePath: UInt64] = [:]
  /// The name the device stores a backup under instead of the one it was sent.
  var backupStoredAs: String?

  struct RenameFailure {
    var skipping: Int
    var remaining: Int
    let error: TransportError
  }
  var deleteFailure: TransportError?
  /// Runs when the next upload starts, before it reads the device's contents.
  var uploadHook: (@Sendable () async -> Void)?
  /// Runs when the next delete starts, before it reads the device's contents.
  var deleteHook: (@Sendable () async -> Void)?
  var listFailure: TransportError?
  var storagesFailure: TransportError?
  var storagesFailing: TransportError?

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
  /// Calls to `forgetCachedItems()`.
  public private(set) var forgetCount = 0
  public private(set) var storagesCallCount = 0

  // MARK: DeviceSession

  public func capabilities() async -> DeviceCapabilities { deviceCapabilities }

  public func storages() async throws(TransportError) -> [StorageInfo] {
    storagesCallCount += 1
    await pauseIfSuspended(.storages)
    if let failure = storagesFailure {
      storagesFailure = nil
      throw failure
    }
    if let failing = storagesFailing { throw failing }
    try requireAvailable()
    return storageInfos
  }

  public func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    await pauseIfSuspended(.list)
    if let failure = listFailure {
      listFailure = nil
      throw failure
    }
    let nodes = try nodes(in: storage)
    try requireFolder(folder, in: nodes)
    return nodes.filter { $0.key.parent == folder }
      .map { listedItem($0.key, $0.value) }
      .sorted { $0.path.description < $1.path.description }
  }

  public func item(at path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    let nodes = try nodes(in: storage)
    guard let node = path == .root ? .folder(modified: .distantPast) : nodes[path] else {
      throw .notFound(path)
    }
    return listedItem(path, node)
  }

  /// The item as the device lists it, with any stale size it reports.
  func listedItem(_ path: RemotePath, _ node: Node) -> RemoteItem {
    let item = Self.item(path, node)
    guard let size = reportedSizes[path] else { return item }
    return RemoteItem(path: path, kind: item.kind, size: size, modified: item.modified)
  }

  @discardableResult
  public func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded {
    let nodes = try nodes(in: storage)
    guard case .file(let data, let modified) = nodes[path] else { throw .notFound(path) }
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
    let listed = RemoteItem(
      path: path, kind: .file, size: reportedSizes[path] ?? total, modified: modified)
    return Downloaded(listed: listed, received: total)
  }

  public func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    await runUploadHook()
    var nodes = try nodes(in: storage)
    guard let parent = path.parent else { throw .invalidName(path.description) }
    try requireFolder(parent, in: nodes)
    guard nodes[path] == nil else { throw .alreadyExists(path) }

    let failure = uploadFailure
    let limit = failure?.afterBytes ?? uploadTruncation
    let data = try Self.read(file, upTo: limit)
    let total = UInt64(data.count)
    guard progress(0, total) else { throw .cancelled }

    let node = Node.file(data, modified: Date())
    nodes[path] = node
    tree[storage] = nodes
    if let failure {
      uploadFailure = nil
      throw failure.error
    }
    guard progress(total, total) else {
      tree[storage]?[path] = nil
      throw .cancelled
    }
    return Self.item(path, node)
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
    if var failure = renameFailure {
      if failure.skipping > 0 {
        failure.skipping -= 1
        renameFailure = failure
      } else {
        failure.remaining -= 1
        renameFailure = failure.remaining > 0 ? failure : nil
        throw failure.error
      }
    }
    guard let parent = path.parent else { throw .invalidName(path.description) }
    guard nodes[path] != nil else { throw .notFound(path) }
    if let actual = backupStoredAs, SafeWriter.isBackup(newName) {
      _ = try relocate(path, to: parent.appending(actual), in: storage)
      throw .nameChangedByDevice(requested: newName, actual: actual)
    }
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

  public func delete(_ path: RemotePath, in storage: StorageID, expecting: [RemoteItem]?)
    async throws(TransportError)
  {
    await runDeleteHook()
    var nodes = try nodes(in: storage)
    if let failure = deleteFailure {
      deleteFailure = nil
      throw failure
    }
    guard nodes[path] != nil else { throw .notFound(path) }
    let doomed = nodes.filter { Self.isSame($0.key, orInside: path) }
    if let expecting { try requireChecked(doomed, at: path, expecting) }
    for key in doomed.keys { nodes[key] = nil }
    tree[storage] = nodes
  }

  /// Counts the calls; the fake remembers nothing a reread would change.
  public func forgetCachedItems() async throws(TransportError) {
    try requireAvailable()
    forgetCount += 1
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
      // A stale listed size belongs to the object, so it moves with it.
      reportedSizes[moved] = reportedSizes.removeValue(forKey: key)
    }
    tree[storage] = nodes
    guard let node = nodes[destination] else { throw .notFound(destination) }
    return listedItem(destination, node)
  }

}

// MARK: Test controls

extension FakeDevice {
  /// Takes a storage away, as removing an SD card does: the device stays attached.
  public func removeStorage(_ id: StorageID) {
    storageInfos.removeAll { $0.id == id }
    tree[id] = nil
  }

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

  /// Returns once `call` is waiting on `suspendNext(_:)`, or the calling task is cancelled, as
  /// a test's time limit does, so a call that never comes fails the test instead of hanging it.
  public func waitUntilSuspended(_ call: SuspendableCall) async {
    if case .waiting = suspensions[call] { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before registering: the handler's release has nothing to resume.
        if Task.isCancelled {
          continuation.resume()
        } else {
          suspensions[call] = .observed(continuation)
        }
      }
    } onCancel: {
      Task { await self.stopObserving(call) }
    }
  }

  private func stopObserving(_ call: SuspendableCall) {
    guard case .observed(let observer) = suspensions[call] else { return }
    suspensions[call] = .armed
    observer.resume()
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

}
