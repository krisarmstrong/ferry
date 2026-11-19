import DeviceKit
import FerryIPC
import Foundation

// MARK: Send to <device>

extension AgentService {
  /// Copies `source` into a scratch file, then uploads it into `Download/` on the device's
  /// internal storage through that storage's domain, so Finder's location shows it. A name the
  /// folder already has is never written over: the file goes beside it as a conflict copy, as a
  /// save from a version the device no longer has does, since Finder Sync has no dialog to ask
  /// Replace or Keep Both. `Download/` is made if the device has none.
  func send(
    _ source: Int32, as name: String, to device: DeviceID,
    progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> ProviderEntry {
    let name = try Self.creatable(name)
    guard let storage = await sendTarget(of: device),
      let domain = await domains.connectedDomain(of: storage)
    else { throw .deviceDisconnected }
    let scratch = try await FileTransfer.copyIn(source, into: scratchFolder)
    defer { FileTransfer.remove(scratch) }
    return try await gated(domain) { route throws(TransportError) in
      let folder = try RemotePath.root.appending(Self.sendFolder)
      try await Self.requireFolder(folder, on: route)
      let path = try folder.appending(name)
      let item = try await transfers.track(
        Self.transfer(path, .toDevice, on: route), report: progress
      ) { handler throws(TransportError) in
        do throws(TransportError) {
          return try await route.writer.write(
            from: scratch, to: path, in: route.storage, replacing: false, progress: handler)
        } catch .alreadyExists {
          return try await ConflictCopy.upload(scratch, beside: path, route, progress: handler)
        }
      }
      return await route.items.created(item)
    }
  }

  /// The device's internal storage: the one keyed `internal`, or, on an MTP device whose
  /// primary storage kept its MTP key, the first it lists, which MTP lists as primary. `nil`
  /// unless the device is ready.
  private func sendTarget(of device: DeviceID) async -> StorageID? {
    guard let attached = await hub.devices().first(where: { $0.id == device }),
      case .ready(let storages) = attached.state
    else { return nil }
    return (storages.first { $0.id.key == StorageKey.internal } ?? storages.first)?.id
  }

  /// Makes `folder` unless the device has it; anything else under its name is in the way.
  private static func requireFolder(_ folder: RemotePath, on route: DomainController.Route)
    async throws(TransportError)
  {
    do throws(TransportError) {
      let existing = try await route.session.item(at: folder, in: route.storage)
      guard existing.kind == .folder else { throw .alreadyExists(folder) }
    } catch .notFound {
      _ = await route.items.created(try await route.session.makeFolder(folder, in: route.storage))
    }
  }

  static let sendFolder = "Download"
}
