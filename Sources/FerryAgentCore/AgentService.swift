import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "AgentService")

/// Serves requests from the app and the FileProvider extension against the hub's sessions.
///
/// Requests come from sandboxed processes, so names and file URLs are checked here: a new name
/// must be one path component, and every file URL must lie inside `allowedRoot` (the app-group
/// container) once symlinks are resolved. Uploads go through the domain's one `SafeWriter`.
/// After a change on the device, the parent folder of every affected path is signalled.
///
/// A request keeps running if its client goes away; its reply is then dropped.
public actor AgentService: AgentHandling {
  private let hub: DeviceHub
  private let domains: DomainController
  private let root: URL

  public init(hub: DeviceHub, domains: DomainController, allowedRoot: URL) {
    self.hub = hub
    self.domains = domains
    root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
  }

  public func handle(_ request: AgentRequest) async -> AgentResponse {
    do throws(TransportError) {
      return try await perform(request)
    } catch {
      log.error("request failed: \(String(describing: error), privacy: .private)")
      return .failure(error)
    }
  }

  private func perform(_ request: AgentRequest) async throws(TransportError) -> AgentResponse {
    switch request {
    case .status:
      return .status(devices: await hub.devices(), providerEnabled: await domains.isUserEnabled())
    case .recheck(let id):
      await hub.recheck(id)
      return .done
    case .eject(let id):
      await domains.eject(id)
      return .done
    case .removeAllDomains:
      try await domains.removeAll()
      return .done
    case .item(let domain, let path):
      let route = try await domains.route(domain)
      return .item(try await route.session.item(at: path, in: route.storage))
    case .list(let domain, let folder):
      let route = try await domains.route(domain)
      return .items(try await route.writer.visibleList(folder, in: route.storage))
    case .fetch(let domain, let path, let file):
      try await fetch(path, in: domain, to: file)
      return .done
    case .create(let domain, let path, let file, let isFolder):
      return .item(try await create(path, in: domain, from: file, isFolder: isFolder))
    case .rename(let domain, let path, let name):
      return .item(try await rename(path, in: domain, to: name))
    case .move(let domain, let path, let folder):
      let route = try await domains.route(domain)
      let item = try await route.session.move(path, toFolder: folder, in: route.storage)
      await signal(domain, [path.parent, folder])
      return .item(item)
    case .replaceContents(let domain, let path, let file):
      return .item(try await write(file, to: path, in: domain, replacing: true))
    case .delete(let domain, let path):
      let route = try await domains.route(domain)
      try await route.session.delete(path, in: route.storage)
      await signal(domain, [path.parent])
      return .done
    }
  }

  private func fetch(_ path: RemotePath, in domain: String, to file: URL)
    async throws(TransportError)
  {
    let target = try checked(file)
    let route = try await domains.route(domain)
    // Replacing, so a file already at the destination is never reported as a collision.
    try await route.session.download(
      path, in: route.storage, to: target, replacing: true, progress: Self.ignoreProgress)
  }

  private func create(_ path: RemotePath, in domain: String, from file: URL?, isFolder: Bool)
    async throws(TransportError) -> RemoteItem
  {
    switch (file, isFolder) {
    case (let file?, false):
      return try await write(file, to: path, in: domain, replacing: false)
    case (nil, true):
      let route = try await domains.route(domain)
      let item = try await route.session.makeFolder(path, in: route.storage)
      await signal(domain, [path.parent])
      return item
    default:
      throw .io("bad request")
    }
  }

  private func rename(_ path: RemotePath, in domain: String, to name: String)
    async throws(TransportError) -> RemoteItem
  {
    guard let validated = try RemotePath.root.appending(name).name else {
      throw .invalidName(name)
    }
    let route = try await domains.route(domain)
    let item = try await route.session.rename(path, to: validated, in: route.storage)
    await signal(domain, [path.parent])
    return item
  }

  private func write(_ file: URL, to path: RemotePath, in domain: String, replacing: Bool)
    async throws(TransportError) -> RemoteItem
  {
    let source = try checked(file)
    let route = try await domains.route(domain)
    let item = try await route.writer.write(
      from: source, to: path, in: route.storage, replacing: replacing,
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

  // MARK: File URLs

  /// The URL with the symlinks in its folder resolved, if it lies strictly inside the allowed
  /// root and is not itself a symlink. A symlink at the leaf is refused rather than resolved:
  /// one whose target does not exist yet stays unresolved, and a download would write through it.
  private func checked(_ url: URL) throws(TransportError) -> URL {
    guard url.isFileURL else { throw .io("url outside container") }
    let standard = url.standardizedFileURL
    let candidate = standard.deletingLastPathComponent().resolvingSymlinksInPath()
      .appending(path: standard.lastPathComponent)
    let inside = root.pathComponents
    guard candidate.pathComponents.count > inside.count,
      candidate.pathComponents.starts(with: inside),
      (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    else { throw .io("url outside container") }
    return candidate
  }
}
