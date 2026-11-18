import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "AgentService")

/// Serves requests from the app and the FileProvider extension against the hub's sessions.
///
/// Requests come from sandboxed processes, so the agent trusts nothing they name. A new name
/// must be one path component. File contents arrive as an open descriptor, never a path: the
/// agent copies between that descriptor and a scratch file of its own (see `FileTransfer`), so
/// it never opens a file a client chose. Uploads go through the domain's one `SafeWriter`. After a
/// change on the device, the parent folder of every affected path is signalled.
///
/// A request keeps running if its client goes away; its reply is then dropped.
public actor AgentService: AgentHandling {
  private let hub: DeviceHub
  private let domains: DomainController

  public init(hub: DeviceHub, domains: DomainController) {
    self.hub = hub
    self.domains = domains
  }

  public func handle(_ request: AgentRequest, file: FileHandle?) async -> AgentResponse {
    do throws(TransportError) {
      guard Self.takesFile(request) == (file != nil) else { throw .io("bad request") }
      return try await perform(request, file: file?.fileDescriptor)
    } catch {
      log.error("request failed: \(String(describing: error), privacy: .private)")
      return .failure(error)
    }
  }

  /// Whether a request must come with a file: a readable one to upload, a writable one to fetch
  /// into.
  private static func takesFile(_ request: AgentRequest) -> Bool {
    switch request {
    case .fetch, .replaceContents: true
    case .create(_, _, let isFolder): !isFolder
    case .status, .recheck, .eject, .removeAllDomains, .item, .list, .rename, .move, .delete:
      false
    }
  }

  /// `file` is present exactly when `takesFile(request)`.
  private func perform(_ request: AgentRequest, file: Int32?) async throws(TransportError)
    -> AgentResponse
  {
    switch (request, file) {
    case (.status, _):
      return .status(devices: await hub.devices(), providerEnabled: await domains.isUserEnabled())
    case (.recheck(let id), _):
      await hub.recheck(id)
      return .done
    case (.eject(let id), _):
      await domains.eject(id)
      return .done
    case (.removeAllDomains, _):
      try await domains.removeAll()
      return .done
    case (.item(let domain, let path), _):
      let route = try await domains.route(domain)
      return .item(try await route.session.item(at: path, in: route.storage))
    case (.list(let domain, let folder), _):
      let route = try await domains.route(domain)
      return .items(try await route.writer.visibleList(folder, in: route.storage))
    case (.fetch(let domain, let path), let file?):
      try await fetch(path, in: domain, into: file)
      return .done
    case (.create(let domain, let path, _), let file?):
      try Self.requireCreatable(path)
      return .item(try await write(file, to: path, in: domain, replacing: false))
    case (.create(let domain, let path, _), nil):
      try Self.requireCreatable(path)
      return .item(try await makeFolder(path, in: domain))
    case (.replaceContents(let domain, let path), let file?):
      return .item(try await write(file, to: path, in: domain, replacing: true))
    case (.rename(let domain, let path, let name), _):
      return .item(try await rename(path, in: domain, to: name))
    case (.move(let domain, let path, let folder), _):
      let route = try await domains.route(domain)
      let item = try await route.session.move(path, toFolder: folder, in: route.storage)
      await signal(domain, [path.parent, folder])
      return .item(item)
    case (.delete(let domain, let path), _):
      let route = try await domains.route(domain)
      try await route.session.delete(path, in: route.storage)
      await signal(domain, [path.parent])
      return .done
    case (.fetch, nil), (.replaceContents, nil):
      throw .io("bad request")
    }
  }

  /// Downloads into a scratch file, then copies it into `target`. Replacing, because the scratch
  /// path is new and nothing else may be there.
  private func fetch(_ path: RemotePath, in domain: String, into target: Int32)
    async throws(TransportError)
  {
    try FileTransfer.requireRegular(target)
    let route = try await domains.route(domain)
    let scratch = FileTransfer.scratchURL()
    defer { FileTransfer.remove(scratch) }
    try await route.session.download(
      path, in: route.storage, to: scratch, replacing: true, progress: Self.ignoreProgress)
    try await FileTransfer.copyOut(scratch, to: target)
  }

  /// A listing deletes any item named like a partial that no writer holds, so the agent never
  /// creates one under a client's name.
  private static func requireCreatable(_ path: RemotePath) throws(TransportError) {
    guard let name = path.name, !SafeWriter.isPartial(name) else {
      throw .invalidName(path.description)
    }
  }

  private func makeFolder(_ path: RemotePath, in domain: String) async throws(TransportError)
    -> RemoteItem
  {
    let route = try await domains.route(domain)
    let item = try await route.session.makeFolder(path, in: route.storage)
    await signal(domain, [path.parent])
    return item
  }

  private func rename(_ path: RemotePath, in domain: String, to name: String)
    async throws(TransportError) -> RemoteItem
  {
    guard let validated = try RemotePath.root.appending(name).name,
      !SafeWriter.isPartial(validated)
    else { throw .invalidName(name) }
    let route = try await domains.route(domain)
    let item = try await route.session.rename(path, to: validated, in: route.storage)
    await signal(domain, [path.parent])
    return item
  }

  /// Copies `source` into a scratch file, then uploads that through the domain's writer.
  private func write(_ source: Int32, to path: RemotePath, in domain: String, replacing: Bool)
    async throws(TransportError) -> RemoteItem
  {
    let route = try await domains.route(domain)
    let scratch = try await FileTransfer.copyIn(source)
    defer { FileTransfer.remove(scratch) }
    let item = try await route.writer.write(
      from: scratch, to: path, in: route.storage, replacing: replacing,
      progress: Self.ignoreProgress)
    await signal(domain, [path.parent])
    return item
  }

  /// Signals each folder once. A `nil` parent is the root's, which no change can affect.
  private func signal(_ domain: String, _ folders: [RemotePath?]) async {
    var signalled: Set<RemotePath> = []
    for folder in folders.compactMap(\.self) where signalled.insert(folder).inserted {
      await domains.signal(domain, folder: folder)
    }
  }

  private static let ignoreProgress: ProgressHandler = { _, _ in true }
}
