import DeviceKit
import FerryIPC
import Foundation

// MARK: Transfers

/// What a content replacement is based on.
struct Replacement {
  let id: ItemID
  let base: ContentVersion?
  let onConflict: ConflictPolicy
}

extension AgentService {
  /// Downloads into a scratch file, then copies it into `target`. Replacing, because the scratch
  /// path is new and nothing else may be there. Returns the item as it arrived: a device with
  /// stale metadata sends more than it lists, and Finder's item takes the real size.
  func fetch(
    _ id: ItemID, in domain: String, into target: Int32,
    progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> ProviderEntry {
    try FileTransfer.requireRegular(target)
    let scratch = FileTransfer.scratchURL(in: scratchFolder)
    defer { FileTransfer.remove(scratch) }
    let entry = try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: id)
      let downloaded = try await transfers.track(
        Self.transfer(path, .toMac, on: route), report: progress
      ) { handler throws(TransportError) in
        try await route.session.download(
          path, in: route.storage, to: scratch, replacing: true, progress: handler)
      }
      return await route.items.downloaded(downloaded)
    }
    try await FileTransfer.copyOut(scratch, to: target)
    return entry
  }

  /// Copies `source` into a scratch file, then uploads that through the domain's writer.
  ///
  /// A file already at the name with exactly these bytes is this create, done before: one whose
  /// reply never reached FileProvider (the extension or this agent went away first), which
  /// FileProvider sends again. It is answered with that file. A collision there would make
  /// FileProvider rename its own copy to "name 2" and send that too, a duplicate of a file the
  /// device already has.
  func upload(
    _ source: Int32, as name: String, in parent: ItemID, of domain: String,
    progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> ProviderEntry {
    let name = try Self.creatable(name)
    let scratch = try await FileTransfer.copyIn(source, into: scratchFolder)
    defer { FileTransfer.remove(scratch) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.writableFolder(parent).appending(name)
      do throws(TransportError) {
        let item = try await transfers.track(
          Self.transfer(path, .toDevice, on: route), report: progress
        ) { handler throws(TransportError) in
          try await route.writer.write(
            from: scratch, to: path, in: route.storage, replacing: false, progress: handler)
        }
        return await route.items.created(item)
      } catch .alreadyExists(let taken) where taken == path {
        guard let same = await sameFile(at: path, as: scratch, on: route) else {
          throw .alreadyExists(taken)
        }
        return await route.items.observed(same)
      }
    }
  }

  /// The device's file at `path` if it holds exactly the bytes of `local`; `nil` if it holds
  /// others or cannot be read.
  private func sameFile(at path: RemotePath, as local: URL, on route: DomainController.Route)
    async -> RemoteItem?
  {
    guard let item = try? await route.session.item(at: path, in: route.storage),
      item.kind == .file, (try? LocalFile.regularFileSize(local)) == item.size
    else { return nil }
    let copy = FileTransfer.scratchURL(in: scratchFolder)
    defer { FileTransfer.remove(copy) }
    do throws(TransportError) {
      try await route.session.download(
        path, in: route.storage, to: copy, replacing: true, progress: { _, _ in true })
      return try LocalFile.sha256(copy) == LocalFile.sha256(local) ? item : nil
    } catch {
      return nil
    }
  }

  /// Copies `source` into a scratch file, then writes that over the file through the writer.
  ///
  /// If the device's file is no longer at `base` (an app on the device, or the user at the
  /// unit, changed it since the Mac read it), the device's file is kept: with `.keepBoth` the
  /// Mac's contents go up beside it as a conflict copy and the device's item is answered as
  /// `.keptOnDevice`, so FileProvider fetches the device's contents; with `.fail` nothing is
  /// written.
  func replace(
    _ replacement: Replacement, with source: Int32, in domain: String,
    progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> AgentResponse {
    let (id, base, onConflict) = (replacement.id, replacement.base, replacement.onConflict)
    let scratch = try await FileTransfer.copyIn(source, into: scratchFolder)
    defer { FileTransfer.remove(scratch) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.changeable(id)
      // The file the save was checked against, which the write then requires to be there still.
      var checked: RemoteItem?
      if let base {
        let current = try await route.session.item(at: path, in: route.storage)
        // As FileProvider holds it: at the size a download delivered (see `delete`).
        let entry = await route.items.observed(current)
        // A file an earlier failed replace put back holds the bytes the save was based on, though
        // it is dated when it went back: a retry of that save is no conflict.
        let restoredFrom = await route.session.partials.original(
          ofRestored: current, in: route.storage)
        let version = restoredFrom.map(ContentVersion.init) ?? ContentVersion(entry.item)
        if entry.item.kind == .file, !version.matches(base) {
          return try await keepDevice(
            entry, onConflict, mac: scratch, on: route, report: progress)
        }
        checked = current
      }
      let item: RemoteItem
      do throws(TransportError) {
        item = try await transfers.track(
          Self.transfer(path, .toDevice, on: route), report: progress
        ) { handler throws(TransportError) in
          try await route.writer.write(
            from: scratch, to: path, in: route.storage, replacing: true, expecting: checked,
            progress: handler)
        }
      } catch .changedOnDevice {
        // The device replaced the file between the check and the write.
        let entry = await route.items.observed(
          try await route.session.item(at: path, in: route.storage))
        return try await keepDevice(
          entry, onConflict, mac: scratch, on: route, report: progress)
      }
      return .entry(await route.items.changed(item, id: id))
    }
  }
}

extension AgentService {
  /// The device's file `entry` is newer than the save: it stays. With `.keepBoth` the Mac's
  /// contents in `mac` go up beside it as a conflict copy, listed in `transfers` and stopped by
  /// the request's cancel like any upload; with `.fail` nothing is written.
  func keepDevice(
    _ entry: ProviderEntry, _ onConflict: ConflictPolicy, mac: URL,
    on route: DomainController.Route, report: @escaping TransferProgressHandler
  ) async throws(TransportError) -> AgentResponse {
    switch onConflict {
    case .fail:
      throw .changedOnDevice(entry.item.path)
    case .keepBoth:
      let path = entry.item.path
      let copy = try await transfers.track(
        Self.transfer(path, .toDevice, on: route), report: report
      ) { handler throws(TransportError) in
        try await ConflictCopy.upload(mac, beside: path, route, progress: handler)
      }
      _ = await route.items.created(copy)
      return .keptOnDevice(entry)
    }
  }
}
