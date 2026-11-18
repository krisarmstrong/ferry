import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "AgentService")

/// Serves requests from the app and the FileProvider extension against the hub's sessions.
///
/// Requests come from sandboxed processes, so the agent trusts nothing they name. An item is
/// named by an `ItemID` the agent assigned, and resolved through the domain's `ItemTable`; a new
/// name must be one path component. File contents arrive as an open descriptor, never a path: the
/// agent copies between that descriptor and a scratch file of its own (see `FileTransfer`), so
/// it never opens a file a client chose. Uploads go through the domain's one `SafeWriter`.
///
/// Every new, changed or vanished item the agent sees, whether from a request that changed the
/// device or a listing that found the device changed, is recorded in the domain's change log and
/// the domain's working set is signalled, so Finder learns of changes made outside it.
///
/// Every operation that resolves an identifier runs through the domain's gate, from the lookup to
/// the table update after the device changed, so a listing can never see the device and the table
/// disagree and drop an item that is only being renamed. The device runs one operation at a time
/// anyway; the copies to and from the client's descriptor stay outside the gate.
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
      log.log(
        level: error.logType,
        "request failed: \(String(describing: error), privacy: .private)")
      return .failure(error)
    }
  }

  /// `file` is present exactly when `takesFile(request)`.
  private func perform(_ request: AgentRequest, file: Int32?) async throws(TransportError)
    -> AgentResponse
  {
    switch (request, file) {
    case (.status, _):
      await hub.firstScan()
      return .status(devices: await hub.devices(), providerEnabled: await domains.isUserEnabled())
    case (.recheck(let id), _):
      await hub.recheck(id)
      return .done
    case (.refresh(let id), _):
      try await domains.refresh(id)
      return .done
    case (.eject(let id), _):
      return .removed(preserved: await domains.eject(id))
    case (.removeAllDomains, _):
      return .removed(preserved: try await domains.removeAll())
    case (.item(let domain, let id), _):
      return .entry(try await item(id, in: domain))
    case (.list(let domain, let folder), _):
      return .entries(try await list(folder, in: domain))
    case (.fetch(let domain, let id), let file?):
      try await fetch(id, in: domain, into: file)
      return .done
    case (.create(let domain, let parent, let name, _), let file?):
      return .entry(try await upload(file, as: name, in: parent, of: domain))
    case (.create(let domain, let parent, let name, _), nil):
      return .entry(try await makeFolder(name, in: parent, of: domain))
    case (.replaceContents(let domain, let id, let base, let onConflict), let file?):
      return .entry(
        try await replace(id, with: file, base: base, onConflict: onConflict, in: domain))
    case (.rename(let domain, let id, let name), _):
      return .entry(try await rename(id, to: name, in: domain))
    case (.move(let domain, let id, let folder), _):
      return .entry(try await move(id, to: folder, in: domain))
    case (.delete(let domain, let id, let base, let recursive), _):
      try await delete(id, base: base, recursive: recursive, in: domain)
      return .done
    case (.changes(let domain, let since), _):
      let changes = try await domains.route(domain).items.changes(since: since)
      return .changes(
        anchor: changes.anchor, updated: changes.updated, deleted: changes.deleted,
        expired: changes.expired)
    case (.workingSet(let domain, let page), _):
      return try await workingSet(page, in: domain)
    case (.fetch, nil), (.replaceContents, nil):
      throw .io("bad request")
    }
  }

  // MARK: Reading

  /// The item as the device has it now. If the device now has another kind of item at its path,
  /// the item Finder asked about is gone.
  private func item(_ id: ItemID, in domain: String) async throws(TransportError)
    -> ProviderEntry
  {
    try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: id)
      let entry = await route.items.observed(
        try await route.session.item(at: path, in: route.storage))
      guard entry.id == id else { throw .unknownItem }
      return entry
    }
  }

  private func list(_ folder: ItemID, in domain: String) async throws(TransportError)
    -> [ProviderEntry]
  {
    try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: folder)
      let items = try await route.writer.visibleList(path, in: route.storage)
      return await route.items.listed(path, children: items)
    }
  }

  /// Downloads into a scratch file, then copies it into `target`. Replacing, because the scratch
  /// path is new and nothing else may be there.
  private func fetch(_ id: ItemID, in domain: String, into target: Int32)
    async throws(TransportError)
  {
    try FileTransfer.requireRegular(target)
    let scratch = FileTransfer.scratchURL()
    defer { FileTransfer.remove(scratch) }
    try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: id)
      try await route.session.download(
        path, in: route.storage, to: scratch, replacing: true, progress: Self.ignoreProgress)
    }
    try await FileTransfer.copyOut(scratch, to: target)
  }

  /// One page of the working set. The page token is the last identifier served, as UTF-8.
  private func workingSet(_ page: Data?, in domain: String) async throws(TransportError)
    -> AgentResponse
  {
    let cursor = try page.map { data throws(TransportError) in
      guard let id = String(data: data, encoding: .utf8).flatMap(ItemID.init(rawValue:)) else {
        throw .io("bad request")
      }
      return id
    }
    let (entries, next) = try await gated(domain) { route in
      await route.items.workingSet(after: cursor, size: Self.workingSetPageSize)
    }
    return .page(entries: entries, next: next.map { Data($0.rawValue.utf8) })
  }

  // MARK: Changing

  /// Copies `source` into a scratch file, then uploads that through the domain's writer.
  private func upload(_ source: Int32, as name: String, in parent: ItemID, of domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    let name = try Self.creatable(name)
    let scratch = try await FileTransfer.copyIn(source)
    defer { FileTransfer.remove(scratch) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: parent).appending(name)
      let item = try await route.writer.write(
        from: scratch, to: path, in: route.storage, replacing: false,
        progress: Self.ignoreProgress)
      return await route.items.created(item)
    }
  }

  private func makeFolder(_ name: String, in parent: ItemID, of domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    let name = try Self.creatable(name)
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: parent).appending(name)
      return await route.items.created(try await route.session.makeFolder(path, in: route.storage))
    }
  }

  /// Copies `source` into a scratch file, then writes that over the file through the writer.
  ///
  /// If the device's file is no longer at `base` (an app on the device, or the user at the
  /// unit, changed it since the Mac read it), the device's file is kept: with `.keepBoth` the
  /// Mac's contents go up beside it as a conflict copy and the device's item is returned, so
  /// FileProvider fetches the device's contents; with `.fail` nothing is written.
  private func replace(
    _ id: ItemID, with source: Int32, base: ContentVersion?, onConflict: ConflictPolicy,
    in domain: String
  ) async throws(TransportError) -> ProviderEntry {
    let scratch = try await FileTransfer.copyIn(source)
    defer { FileTransfer.remove(scratch) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: id)
      if let base {
        let current = try await route.session.item(at: path, in: route.storage)
        if current.kind == .file, ContentVersion(current) != base {
          let entry = await route.items.observed(current)
          switch onConflict {
          case .fail:
            throw .changedOnDevice(path)
          case .keepBoth:
            _ = await route.items.created(
              try await ConflictCopy.upload(scratch, beside: path, route))
            return entry
          }
        }
      }
      let item = try await route.writer.write(
        from: scratch, to: path, in: route.storage, replacing: true,
        progress: Self.ignoreProgress)
      return await route.items.changed(item, id: id)
    }
  }

  private func rename(_ id: ItemID, to name: String, in domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    let validated = try Self.creatable(name)
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.changeable(id)
      let item = try await route.session.rename(path, to: validated, in: route.storage)
      await route.items.moved(path, to: item.path)
      return await route.items.changed(item, id: id)
    }
  }

  private func move(_ id: ItemID, to folder: ItemID, in domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    try await gated(domain) { route throws(TransportError) in
      let path = try await route.changeable(id)
      let destination = try await route.path(of: folder)
      let item = try await route.session.move(path, toFolder: destination, in: route.storage)
      await route.items.moved(path, to: item.path)
      return await route.items.changed(item, id: id)
    }
  }

  /// Deletes the item as the device has it now. A file the device changed since `base` is kept
  /// and its new state recorded, so FileProvider puts it back. A folder is deleted with its
  /// contents only if `recursive`: without it, one that holds anything Finder would show is
  /// kept, since Finder may have last seen it empty. An item already gone, from the table or
  /// from the device, is deleted already: FileProvider expects success.
  private func delete(
    _ id: ItemID, base: ContentVersion?, recursive: Bool, in domain: String
  ) async throws(TransportError) {
    try await gated(domain) { route throws(TransportError) in
      guard id != .root else { throw .unsupported("changing the storage root") }
      guard let path = await route.items.path(for: id) else { return }
      let current: RemoteItem
      do throws(TransportError) {
        current = try await route.session.item(at: path, in: route.storage)
      } catch .notFound {
        await route.items.removed(path)
        return
      }
      switch current.kind {
      case .file:
        if let base, ContentVersion(current) != base {
          _ = await route.items.observed(current)
          throw .changedOnDevice(path)
        }
      case .folder:
        // The listing that checks also reaps partials abandoned in the folder, which Finder
        // never shows.
        if !recursive, try await !route.writer.visibleList(path, in: route.storage).isEmpty {
          throw .directoryNotEmpty(path)
        }
      }
      try await route.session.delete(path, in: route.storage)
      await route.items.removed(path)
    }
  }

  /// Runs `body` on the domain's route inside its gate, then signals the domain's working set if
  /// `body` recorded a change, even one followed by a failure.
  private func gated<T: Sendable>(
    _ domain: String, _ body: (DomainController.Route) async throws(TransportError) -> T
  ) async throws(TransportError) -> T {
    let route = try await domains.route(domain)
    let (result, changed) = await route.items.gate.run {
      () async -> (Result<T, TransportError>, Bool) in
      let before = await route.items.changeCount
      let result: Result<T, TransportError>
      do throws(TransportError) {
        result = .success(try await body(route))
      } catch {
        result = .failure(error)
      }
      return (result, await route.items.changeCount != before)
    }
    if changed {
      await domains.signal(domain)
    }
    if case .failure(.storageNotFound) = result {
      // The device is still attached but the storage is gone (an SD card taken out). Its
      // storages are read again, so the domain disconnects rather than looking empty.
      await hub.recheck(route.storage.device)
    }
    return try result.get()
  }

  static let ignoreProgress: ProgressHandler = { _, _ in true }
  static let workingSetPageSize = 500
}

// MARK: Validating requests

extension AgentService {
  /// Whether a request must come with a file: a readable one to upload, a writable one to fetch
  /// into.
  private static func takesFile(_ request: AgentRequest) -> Bool {
    switch request {
    case .fetch, .replaceContents: true
    case .create(_, _, _, let isFolder): !isFolder
    case .status, .recheck, .refresh, .eject, .removeAllDomains, .item, .list, .rename, .move,
      .delete, .changes, .workingSet:
      false
    }
  }

  /// A name a client may give an item: one path component, never a partial's or a backup's. A
  /// listing hides those and deletes abandoned ones, so the agent never creates one under a
  /// client's name.
  private static func creatable(_ name: String) throws(TransportError) -> String {
    guard let validated = try RemotePath.root.appending(name).name,
      !SafeWriter.isPartial(validated), !SafeWriter.isBackup(validated)
    else { throw .invalidName(name) }
    return validated
  }
}

extension DomainController.Route {
  /// The path of an item this domain's table knows.
  func path(of id: ItemID) async throws(TransportError) -> RemotePath {
    guard let path = await items.path(for: id) else { throw .unknownItem }
    return path
  }

  /// The path of an item that may be renamed, moved or deleted: anything but the root.
  func changeable(_ id: ItemID) async throws(TransportError) -> RemotePath {
    guard id != .root else { throw .unsupported("changing the storage root") }
    return try await path(of: id)
  }
}
