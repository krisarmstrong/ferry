import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers

let domain = "domain-1"
let epoch = Date(timeIntervalSince1970: 1_700_000_000)

func path(_ string: String) throws -> RemotePath {
  try RemotePath(string)
}

func file(_ string: String, size: UInt64 = 0, modified: Date = epoch) throws -> RemoteItem {
  RemoteItem(path: try path(string), kind: .file, size: size, modified: modified)
}

func folder(_ string: String) throws -> RemoteItem {
  RemoteItem(path: try path(string), kind: .folder, size: 0, modified: epoch)
}

/// An agent holding one storage in memory. Like `MTPSession`, a new name collides with a sibling
/// that shares its `collisionKey`, except the item being renamed. Like the real agent, it gives
/// each item a random identifier that a rename or move keeps.
actor FakeAgent: AgentSending {
  private(set) var items: [RemotePath: RemoteItem] = [
    .root: RemoteItem(
      path: .root, kind: .folder, size: 0, modified: .distantPast)
  ]
  private var paths: [ItemID: RemotePath] = [.root: .root]
  private(set) var contents: [RemotePath: Data] = [:]
  private(set) var requests: [AgentRequest] = []
  /// Answered to every request instead of performing it.
  var failure: TransportError?
  /// Thrown by `send` itself, as `AgentClient` does when the connection is lost.
  var thrown: TransportError?
  /// Reported, half then all of it, as a fetch's progress.
  var progressTotal: UInt64?
  /// The next `.replaceContents` keeps the device's file, as the agent does when the device
  /// changed it since the save's base.
  var keepDeviceVersion = false
  /// Answered to the next `.delete` instead of performing it.
  var deleteFailure: TransportError?
  /// Written into the fetch target before failing, as a download cut short would.
  var fetchFailure: TransportError?
  /// Answered to `.changes`: the changes since `changeAnchor`, which an older anchor finds
  /// expired.
  var pendingChanges: (updated: [ProviderEntry], deleted: [ItemID]) = ([], [])
  let changeAnchor = Data([1])
  let nextAnchor = Data([2])
  /// Writes a partial download into the fetch target, then waits until the caller is cancelled
  /// and throws `.cancelled`, as `AgentClient` does for a cancelled call. Yields to
  /// `fetchStarted` once it is waiting.
  var parkFetches = false
  let fetchStarted: AsyncStream<Void>
  private let fetchStartedContinuation: AsyncStream<Void>.Continuation
  /// Parks creates until this many have arrived, then answers them all.
  var parkCreatesUntil = 0
  private var parked: [CheckedContinuation<Void, Never>] = []

  init(_ seed: [RemoteItem] = [], contents: [RemotePath: Data] = [:]) {
    (fetchStarted, fetchStartedContinuation) = AsyncStream.makeStream(of: Void.self)
    for item in seed {
      items[item.path] = item
      paths[.random()] = item.path
    }
    self.contents = contents
  }

  /// The identifier of the item at `path`.
  func id(_ path: RemotePath) throws -> ItemID {
    try #require(paths.first { $0.value == path }?.key)
  }

  /// The identifier FileProvider has for the item at `path`.
  func identifier(_ path: RemotePath) throws -> NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(try id(path))
  }

  private func changeReply(_ since: Data?) -> AgentResponse {
    switch since {
    case nil:
      .changes(anchor: changeAnchor, updated: [], deleted: [], expired: false)
    case changeAnchor:
      .changes(
        anchor: nextAnchor, updated: pendingChanges.updated, deleted: pendingChanges.deleted,
        expired: false)
    default:
      .changes(anchor: nextAnchor, updated: [], deleted: [], expired: true)
    }
  }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError)
    -> AgentResponse
  {
    requests.append(request)
    if let thrown { throw thrown }
    if let failure { return .failure(failure) }
    if case .fetch = request, parkFetches {
      try? file?.write(contentsOf: Data("par".utf8))
      fetchStartedContinuation.yield()
      try? await Task.sleep(for: .seconds(3600))
      throw .cancelled
    }
    if case .fetch = request, let total = progressTotal {
      progress?(total / 2, total)
      progress?(total, total)
    }
    do {
      return try await perform(request, file: file)
    } catch {
      return .failure(error)
    }
  }

  private func perform(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
    -> AgentResponse
  {
    switch request {
    case .item(_, let id):
      return .entry(try entry(existing(try path(id)), id: id))
    case .list(_, let folder):
      return .entries(try listing(folder))
    case .fetch(_, let id):
      return .entry(try fetched(id, into: file))
    case .create(_, let parent, let name, let isFolder):
      let created = try await create(
        try path(parent).appending(name), isFolder: isFolder, from: file)
      let id = ItemID.random()
      paths[id] = created.path
      return .entry(try entry(created, id: id))
    case .rename(_, let id, let name):
      let source = try existing(try path(id))
      guard let parent = source.path.parent else { throw .notFound(source.path) }
      let renamed = try parent.appending(name)
      try requireFree(renamed, except: source.path)
      return .entry(try entry(relocate(source, to: renamed, id: id), id: id))
    case .move(_, let id, let folder):
      let source = try existing(try path(id))
      guard let name = source.path.name else { throw .notFound(source.path) }
      let moved = try path(folder).appending(name)
      try requireFree(moved, except: nil)
      return .entry(try entry(relocate(source, to: moved, id: id), id: id))
    case .replaceContents(_, let id, _, _):
      let old = try existing(try path(id))
      if keepDeviceVersion {
        keepDeviceVersion = false
        return .keptOnDevice(try entry(old, id: id))
      }
      let data = (try? file?.readToEnd()) ?? Data()
      let item = RemoteItem(
        path: old.path, kind: .file, size: UInt64(data.count),
        modified: old.modified.addingTimeInterval(60))
      items[old.path] = item
      contents[old.path] = data
      return .entry(try entry(item, id: id))
    case .delete(_, let id, _, _):
      try delete(id)
      return .done
    case .changes(_, let since):
      return changeReply(since)
    case .workingSet(_, let page):
      return try workingSetPage(page)
    case .status, .recheck, .recheckADB, .refresh, .eject, .removeAllDomains, .connectAddress,
      .pair, .connectWireless, .enableWireless, .forgetWireless, .confirmWireless, .ignoreWireless:
      throw .unsupported("\(request)")
    }
  }

  /// Writes the file into `file` and returns it as received.
  private func fetched(_ id: ItemID, into file: FileHandle?) throws(TransportError)
    -> ProviderEntry
  {
    let path = try path(id)
    try fetch(path, into: file)
    let listed = try existing(path)
    let received = RemoteItem(
      path: path, kind: .file, size: UInt64(contents[path]?.count ?? 0),
      modified: listed.modified)
    return try entry(received, id: id)
  }

  private func delete(_ id: ItemID) throws(TransportError) {
    if let deleteFailure {
      self.deleteFailure = nil
      throw deleteFailure
    }
    let path = try path(id)
    _ = try existing(path)
    items[path] = nil
    paths[id] = nil
  }

  private func listing(_ folder: ItemID) throws(TransportError) -> [ProviderEntry] {
    let folderPath = try path(folder)
    let children = items.values.filter { $0.path.parent == folderPath }
      .sorted { $0.path.description < $1.path.description }
    var entries: [ProviderEntry] = []
    for item in children {
      entries.append(try entry(item, id: id(for: item.path)))
    }
    return entries
  }

  /// Pages of two after a cursor, the last identifier served, like the agent's pages of 500.
  private func workingSetPage(_ page: Data?) throws(TransportError) -> AgentResponse {
    let cursor = page.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let remaining = paths.filter { $0.key != .root && $0.key.rawValue > cursor }
      .sorted { $0.key.rawValue < $1.key.rawValue }
    var entries: [ProviderEntry] = []
    for (id, path) in remaining.prefix(2) {
      entries.append(try entry(try existing(path), id: id))
    }
    let next = remaining.count > 2 ? entries.last.map { Data($0.id.rawValue.utf8) } : nil
    return .page(entries: entries, next: next)
  }

  private func path(_ id: ItemID) throws(TransportError) -> RemotePath {
    guard let path = paths[id] else { throw .unknownItem }
    return path
  }

  private func id(for path: RemotePath) throws(TransportError) -> ItemID {
    guard let id = paths.first(where: { $0.value == path })?.key else { throw .notFound(path) }
    return id
  }

  private func entry(_ item: RemoteItem, id: ItemID) throws(TransportError) -> ProviderEntry {
    ProviderEntry(id: id, parent: try self.id(for: item.path.parent ?? .root), item: item)
  }

  private func fetch(_ path: RemotePath, into file: FileHandle?) throws(TransportError) {
    let data = contents[path] ?? Data()
    do {
      try file?.write(contentsOf: fetchFailure == nil ? data : data.prefix(1))
    } catch {
      throw .io(error.localizedDescription)
    }
    if let fetchFailure { throw fetchFailure }
  }

  private func create(_ path: RemotePath, isFolder: Bool, from file: FileHandle?)
    async throws(TransportError) -> RemoteItem
  {
    await parkIfAsked()
    try requireFree(path, except: nil)
    let data = (try? file?.readToEnd()) ?? Data()
    let item = RemoteItem(
      path: path, kind: isFolder ? .folder : .file, size: UInt64(data.count), modified: epoch)
    items[path] = item
    contents[path] = isFolder ? nil : data
    return item
  }

  private func existing(_ path: RemotePath) throws(TransportError) -> RemoteItem {
    guard let item = items[path] else { throw .notFound(path) }
    return item
  }

  /// `MTPSession.requireFree`: a sibling sharing the collision key, other than `except`.
  private func requireFree(_ path: RemotePath, except: RemotePath?) throws(TransportError) {
    guard let name = path.name else { throw .alreadyExists(path) }
    let key = RemotePath.collisionKey(name)
    let clash = items.keys.contains {
      $0.parent == path.parent && $0 != except
        && $0.name.map(RemotePath.collisionKey) == key
    }
    if clash { throw .alreadyExists(path) }
  }

  private func relocate(_ source: RemoteItem, to path: RemotePath, id: ItemID) -> RemoteItem {
    let item = RemoteItem(
      path: path, kind: source.kind, size: source.size, modified: source.modified)
    items[source.path] = nil
    items[path] = item
    paths[id] = path
    contents[path] = contents.removeValue(forKey: source.path)
    return item
  }

  /// Parks until enough creates arrive, or until a parked caller is cancelled, as a test's time
  /// limit does, so a backend that serializes fails the test instead of hanging it.
  private func parkIfAsked() async {
    guard parkCreatesUntil > 0 else { return }
    guard parked.count + 1 == parkCreatesUntil, !Task.isCancelled else {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled {
            continuation.resume()
          } else {
            parked.append(continuation)
          }
        }
      } onCancel: {
        Task { await self.unpark() }
      }
      return
    }
    unpark()
  }

  private func unpark() {
    parkCreatesUntil = 0
    for continuation in parked { continuation.resume() }
    parked = []
  }
}

// MARK: Test controls

extension FakeAgent {
  func set(failure: TransportError?, thrown: TransportError? = nil) {
    self.failure = failure
    self.thrown = thrown
  }

  func set(progressTotal: UInt64) {
    self.progressTotal = progressTotal
  }

  func keepDeviceVersionOnNextSave() {
    keepDeviceVersion = true
  }

  func set(deleteFailure: TransportError) {
    self.deleteFailure = deleteFailure
  }

  func set(fetchFailure: TransportError) {
    self.fetchFailure = fetchFailure
  }

  func set(changes updated: [ProviderEntry], deleted: [ItemID]) {
    pendingChanges = (updated, deleted)
  }

  func parkFetchesUntilCancelled() {
    parkFetches = true
  }

  func park(until count: Int) {
    parkCreatesUntil = count
  }
}
