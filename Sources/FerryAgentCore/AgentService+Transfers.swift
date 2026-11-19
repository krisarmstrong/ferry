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
  func upload(
    _ source: Int32, as name: String, in parent: ItemID, of domain: String,
    progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> ProviderEntry {
    let name = try Self.creatable(name)
    let scratch = try await FileTransfer.copyIn(source, into: scratchFolder)
    defer { FileTransfer.remove(scratch) }
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.writableFolder(parent).appending(name)
      let item = try await transfers.track(
        Self.transfer(path, .toDevice, on: route), report: progress
      ) { handler throws(TransportError) in
        try await route.writer.write(
          from: scratch, to: path, in: route.storage, replacing: false, progress: handler)
      }
      return await route.items.created(item)
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
        if entry.item.kind == .file, !ContentVersion(entry.item).matches(base) {
          return try await ConflictCopy.keepDevice(
            entry, onConflict, mac: scratch, on: route, transfers: transfers, report: progress)
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
        return try await ConflictCopy.keepDevice(
          entry, onConflict, mac: scratch, on: route, transfers: transfers, report: progress)
      }
      return .entry(await route.items.changed(item, id: id))
    }
  }
}
