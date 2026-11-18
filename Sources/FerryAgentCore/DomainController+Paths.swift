import DeviceKit
import FerryIPC

// MARK: Resolving request paths

extension DomainController.Route {
  /// The path of an item this domain's table knows.
  func path(of id: ItemID) async throws(TransportError) -> RemotePath {
    guard let path = await items.path(for: id) else { throw .unknownItem }
    return path
  }

  /// The path of an item that may be renamed, moved or replaced: anything but the root, and
  /// nothing in a package-named folder, which is read-only from the Mac.
  func changeable(_ id: ItemID) async throws(TransportError) -> RemotePath {
    guard id != .root else { throw .unsupported("changing the storage root") }
    let path = try await path(of: id)
    // An item the table knows only as a parent is a folder.
    let isFolder = await items.kind(at: path) != .file
    if path.isInPackageFolder(isFolder: isFolder) { throw .readOnly(path) }
    return path
  }

  /// The path of a folder new items may go into: not a package-named one, or one inside it.
  func writableFolder(_ id: ItemID) async throws(TransportError) -> RemotePath {
    let path = try await path(of: id)
    if path.isInPackageFolder(isFolder: true) { throw .readOnly(path) }
    return path
  }
}
