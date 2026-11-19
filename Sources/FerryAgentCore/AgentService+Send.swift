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
    guard let domain = await sendDomain(of: device) else { throw .deviceDisconnected }
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

  /// Every device, for the Finder extension's menu, with whether a file can go to it now.
  func finderDevices() async -> [DeviceSummary] {
    var summaries: [DeviceSummary] = []
    for device in await hub.devices() {
      let ready = await sendDomain(of: device) != nil
      summaries.append(
        DeviceSummary(id: device.id, name: device.info.name, method: device.method, ready: ready))
    }
    return summaries
  }

  /// The connected domain of the device's internal storage, which a send writes to; `nil` unless
  /// the device is ready and that storage has its Finder location.
  private func sendDomain(of device: DeviceID) async -> String? {
    guard let attached = await hub.devices().first(where: { $0.id == device }) else { return nil }
    return await sendDomain(of: attached)
  }

  /// The internal storage is the one keyed `internal`, or, on an MTP device whose primary
  /// storage kept its MTP key, the first it lists, which MTP lists as primary.
  private func sendDomain(of device: AttachedDevice) async -> String? {
    guard case .ready(let storages) = device.state,
      let storage = storages.first(where: { $0.id.key == StorageKey.internal }) ?? storages.first
    else { return nil }
    return await domains.connectedDomain(of: storage.id)
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
