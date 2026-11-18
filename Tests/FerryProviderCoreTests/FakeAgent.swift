import DeviceKit
import FerryIPC
import FileProvider
import Foundation
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
/// that shares its `collisionKey`, except the item being renamed.
actor FakeAgent: AgentSending {
  private(set) var items: [RemotePath: RemoteItem] = [
    .root: RemoteItem(
      path: .root, kind: .folder, size: 0, modified: .distantPast)
  ]
  private(set) var contents: [RemotePath: Data] = [:]
  private(set) var requests: [AgentRequest] = []
  /// Answered to every request instead of performing it.
  var failure: TransportError?
  /// Thrown by `send` itself, as `AgentClient` does when the connection is lost.
  var thrown: TransportError?
  /// Written into the fetch target before failing, as a download cut short would.
  var fetchFailure: TransportError?
  /// Parks creates until this many have arrived, then answers them all.
  var parkCreatesUntil = 0
  private var parked: [CheckedContinuation<Void, Never>] = []

  init(_ seed: [RemoteItem] = [], contents: [RemotePath: Data] = [:]) {
    for item in seed { items[item.path] = item }
    self.contents = contents
  }

  func set(failure: TransportError?, thrown: TransportError? = nil) {
    self.failure = failure
    self.thrown = thrown
  }

  func set(fetchFailure: TransportError) {
    self.fetchFailure = fetchFailure
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
    case .item(_, let path):
      return .item(try existing(path))
    case .list(_, let folder):
      return .items(items.values.filter { $0.path.parent == folder })
    case .fetch(_, let path):
      try fetch(path, into: file)
      return .done
    case .create(_, let path, let isFolder):
      return .item(try await create(path, isFolder: isFolder, from: file))
    case .rename(_, let path, let name):
      let source = try existing(path)
      guard let parent = path.parent else { throw .notFound(path) }
      let renamed = try parent.appending(name)
      try requireFree(renamed, except: path)
      return .item(relocate(source, to: renamed))
    case .move(_, let path, let folder):
      let source = try existing(path)
      guard let name = path.name else { throw .notFound(path) }
      let moved = try folder.appending(name)
      try requireFree(moved, except: nil)
      return .item(relocate(source, to: moved))
    case .replaceContents(_, let path):
      let old = try existing(path)
      let data = (try? file?.readToEnd()) ?? Data()
      let item = RemoteItem(
        path: path, kind: .file, size: UInt64(data.count),
        modified: old.modified.addingTimeInterval(60))
      items[path] = item
      contents[path] = data
      return .item(item)
    case .delete(_, let path):
      _ = try existing(path)
      items[path] = nil
      return .done
    case .status, .recheck, .eject, .removeAllDomains:
      throw .unsupported("\(request)")
    }
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

  private func relocate(_ source: RemoteItem, to path: RemotePath) -> RemoteItem {
    let item = RemoteItem(
      path: path, kind: source.kind, size: source.size, modified: source.modified)
    items[source.path] = nil
    items[path] = item
    contents[path] = contents.removeValue(forKey: source.path)
    return item
  }

  private func parkIfAsked() async {
    guard parkCreatesUntil > 0 else { return }
    guard parked.count + 1 == parkCreatesUntil else {
      await withCheckedContinuation { parked.append($0) }
      return
    }
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
