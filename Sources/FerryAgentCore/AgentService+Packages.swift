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
  ///
  /// The tree comes from the device, so it is walked within `packageBudget` (depth, entries,
  /// bytes), with the Mac's free space checked before each file; past either, the fetch fails
  /// and the partial tree is removed.
  func packageFetch(
    _ id: ItemID, in domain: String, into target: Int32,
    progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> ProviderEntry? {
    let scratch = FileTransfer.scratchURL()
    defer { FileTransfer.removeTree(scratch) }
    let entry = try await gated(domain) { route throws(TransportError) -> ProviderEntry? in
      let path = try await route.path(of: id)
      guard Packages.documentType(named: path.name ?? "") != nil else { return nil }
      let item = try await route.session.item(at: path, in: route.storage)
      guard item.kind == .folder else { return nil }
      try FileTransfer.makeFolder(scratch)
      let start = Self.transfer(path, .toMac, on: route)
      let budget = packageBudget
      try await transfers.track(start, report: progress) { handler throws(TransportError) in
        var walk = TreeWalk(route: route, usage: TreeBudget.Usage(budget), progress: handler)
        try await Self.download(tree: path, into: scratch, depth: 1, walk: &walk)
      }
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

  /// What a package download walks with: the device, what it has used of the budget, and where
  /// each file's progress goes.
  private struct TreeWalk {
    let route: DomainController.Route
    var usage: TreeBudget.Usage
    let progress: ProgressHandler
  }

  /// Downloads the device folder `folder` and everything in it into the local folder `local`,
  /// counting each entry `depth` folders down against the walk's budget.
  private static func download(
    tree folder: RemotePath, into local: URL, depth: Int, walk: inout TreeWalk
  ) async throws(TransportError) {
    let route = walk.route
    for child in try await route.session.list(folder, in: route.storage) {
      guard let name = child.path.name else { continue }
      let target = local.appending(path: name)
      switch child.kind {
      case .folder:
        try walk.usage.add(depth: depth)
        try FileTransfer.makeFolder(target)
        try await download(tree: child.path, into: target, depth: depth + 1, walk: &walk)
      case .file:
        try walk.usage.add(depth: depth, size: child.size)
        try LocalFile.requireSpace(child.size, at: local)
        try await route.session.download(
          child.path, in: route.storage, to: target, replacing: false, progress: walk.progress)
      }
    }
  }
}
