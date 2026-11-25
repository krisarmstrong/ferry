import DeviceKit

// MARK: One listing per write

/// A write lists its folder once (see `WriteListing`): `folder` serves the write's later checks
/// from that listing, which `recordInWrite` keeps up to date with the write's own uploads and
/// renames. Only objects the write made are trusted to it; anything else is resolved afresh.
extension MTPSession {
  /// The folder from the current write's listing of it, or `nil` outside a write that listed
  /// it, or once its cached listing is gone.
  func listedInWrite(_ path: RemotePath, storage: UInt32) async throws(TransportError) -> Folder? {
    guard WriteListing.current?.value(for: Self.listingKey(path, storage), as: Bool.self) == true,
      let children = await resolver.cachedEntries(in: path, storage: storage)
    else { return nil }
    return Folder(id: try await resolver.objectID(for: path, storage: storage), children: children)
  }

  /// Within a write that listed the folder of `path`, records the object `id`, now at `path`, as
  /// the device reports it in that listing, so the write's next check sees the write's own
  /// change.
  func recordInWrite(_ id: UInt32, at path: RemotePath, storage: UInt32)
    async throws(TransportError)
  {
    guard let scope = WriteListing.current, let folder = path.parent,
      scope.value(for: Self.listingKey(folder, storage), as: Bool.self) == true
    else { return }
    await resolver.recorded(try await device.metadata(objectID: id), in: folder, storage: storage)
    scope.record(true, for: Self.ownKey(path, storage))
  }

  /// Whether the current write made the object now at `path`, so the write's listing knows it
  /// as it is. Anything else may have changed on the device since that listing.
  static func isOwnedByWrite(_ path: RemotePath, _ storage: UInt32) -> Bool {
    WriteListing.current?.value(for: ownKey(path, storage), as: Bool.self) == true
  }

  static func listingKey(_ folder: RemotePath, _ storage: UInt32) -> String {
    "mtp|\(storage)|\(folder.description)"
  }

  private static func ownKey(_ path: RemotePath, _ storage: UInt32) -> String {
    "mtp-own|\(storage)|\(path.description)"
  }
}
