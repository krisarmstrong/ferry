import DeviceKit
import FerryIPC
import Foundation

// MARK: Document packages

/// A document package (see `Packages`) is one item to FileProvider, so it crosses as one
/// `PackageArchive`: fetched whole, created whole and replaced whole. What it holds is never an
/// item of its own (see `list`).
extension AgentService {
  /// If `id` is a document package, downloads its tree into a scratch folder, writes it into
  /// `target` as an archive and returns the package's item; otherwise `nil`, for an ordinary
  /// fetch.
  func packageFetch(_ id: ItemID, in domain: String, into target: Int32)
    async throws(TransportError) -> ProviderEntry?
  {
    let scratch = FileTransfer.scratchURL()
    defer { FileTransfer.removeTree(scratch) }
    let entry = try await gated(domain) { route throws(TransportError) -> ProviderEntry? in
      let path = try await route.path(of: id)
      guard Packages.documentType(named: path.name ?? "") != nil else { return nil }
      let item = try await route.session.item(at: path, in: route.storage)
      guard item.kind == .folder else { return nil }
      try FileTransfer.makeFolder(scratch)
      try await Self.download(tree: path, of: route, into: scratch)
      return await route.items.observed(item)
    }
    guard let entry else { return nil }
    try FileTransfer.writeArchive(of: scratch, to: target)
    return entry
  }

  /// Makes the package `name` in `parent` from the archive in `source`.
  func createPackage(
    from source: Int32, as name: String, in parent: ItemID, of domain: String
  ) async throws(TransportError) -> ProviderEntry {
    let name = try Self.creatable(name)
    let tree = try await FileTransfer.extractArchive(source)
    defer { FileTransfer.removeTree(tree) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: parent).appending(name)
      let item = try await route.writer.writeTree(
        from: tree, to: path, in: route.storage, replacing: false)
      return await route.items.created(item)
    }
  }

  /// Replaces the package `id` with the archive in `source`.
  func replacePackage(_ id: ItemID, from source: Int32, in domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    let tree = try await FileTransfer.extractArchive(source)
    defer { FileTransfer.removeTree(tree) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.changeable(id)
      let item = try await route.writer.writeTree(
        from: tree, to: path, in: route.storage, replacing: true)
      await route.items.removedContents(of: path)
      return await route.items.changed(item, id: id)
    }
  }

  /// Downloads the device folder `folder` and everything in it into the local folder `local`.
  private static func download(
    tree folder: RemotePath, of route: DomainController.Route, into local: URL
  ) async throws(TransportError) {
    for child in try await route.session.list(folder, in: route.storage) {
      guard let name = child.path.name else { continue }
      let target = local.appending(path: name)
      switch child.kind {
      case .folder:
        try FileTransfer.makeFolder(target)
        try await download(tree: child.path, of: route, into: target)
      case .file:
        try await route.session.download(
          child.path, in: route.storage, to: target, replacing: false,
          progress: AgentService.ignoreProgress)
      }
    }
  }
}
