import DeviceKit
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

/// What FileProvider hands the extension for a new or changed item.
final class Template: NSObject, NSFileProviderItem {
  let itemIdentifier: NSFileProviderItemIdentifier
  let parentItemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let contentType: UTType

  init(
    id: String = "new", parent: NSFileProviderItemIdentifier, filename: String,
    contentType: UTType = .data
  ) {
    itemIdentifier = NSFileProviderItemIdentifier(id)
    parentItemIdentifier = parent
    self.filename = filename
    self.contentType = contentType
  }
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
  /// Written into the fetch target before failing, as a download cut short would.
  var fetchFailure: TransportError?
  /// Answered to `.changes`: the changes since `changeAnchor`, which an older anchor finds
  /// expired.
  var pendingChanges: (updated: [ProviderEntry], deleted: [ItemID]) = ([], [])
  let changeAnchor = Data([1])
  let nextAnchor = Data([2])
  /// Parks creates until this many have arrived, then answers them all.
  var parkCreatesUntil = 0
  private var parked: [CheckedContinuation<Void, Never>] = []

  init(_ seed: [RemoteItem] = [], contents: [RemotePath: Data] = [:]) {
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

  func set(failure: TransportError?, thrown: TransportError? = nil) {
    self.failure = failure
    self.thrown = thrown
  }

  func set(fetchFailure: TransportError) {
    self.fetchFailure = fetchFailure
  }

  func set(changes updated: [ProviderEntry], deleted: [ItemID]) {
    pendingChanges = (updated, deleted)
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

  func park(until count: Int) {
    parkCreatesUntil = count
  }

  func send(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
    -> AgentResponse
  {
    requests.append(request)
    if let thrown { throw thrown }
    if let failure { return .failure(failure) }
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
      try fetch(try path(id), into: file)
      return .done
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
    case .replaceContents(_, let id):
      let old = try existing(try path(id))
      let data = (try? file?.readToEnd()) ?? Data()
      let item = RemoteItem(
        path: old.path, kind: .file, size: UInt64(data.count),
        modified: old.modified.addingTimeInterval(60))
      items[old.path] = item
      contents[old.path] = data
      return .entry(try entry(item, id: id))
    case .delete(_, let id):
      let path = try path(id)
      _ = try existing(path)
      items[path] = nil
      paths[id] = nil
      return .done
    case .changes(_, let since):
      return changeReply(since)
    case .status, .recheck, .eject, .removeAllDomains:
      throw .unsupported("\(request)")
    }
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

func scratchDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appending(
    path: "FerryProviderCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

func writeContents(_ data: Data, in dir: URL) throws -> URL {
  let url = dir.appending(path: "upload-\(UUID().uuidString)")
  try data.write(to: url)
  return url
}
