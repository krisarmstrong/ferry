import DeviceKit
import FerryIPC
import Foundation
import UniformTypeIdentifiers

// MARK: Validating requests

extension AgentService {
  /// A folder named like a package (`Notes.rtfd`, `Ferry.app`), which FileProvider handles as
  /// one item: deleting it means deleting what is inside it.
  static func isPackage(_ path: RemotePath) -> Bool {
    guard let name = path.name else { return false }
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .package) else {
      return false
    }
    return type.isDeclared
  }

  /// A transfer of the item at `path` starting on `route`'s device, its size not known yet.
  static func transfer(
    _ path: RemotePath, _ direction: ActiveTransfer.Direction, on route: DomainController.Route
  ) -> ActiveTransfer {
    ActiveTransfer(
      device: route.storage.device, name: path.name ?? "", direction: direction, completed: 0,
      total: 0)
  }

  /// Whether a request must come with a file: a readable one to upload, a writable one to fetch
  /// into.
  static func takesFile(_ request: AgentRequest) -> Bool {
    switch request {
    case .fetch, .replaceContents, .createPackage, .replacePackage: true
    case .create(_, _, _, let isFolder): !isFolder
    case .status, .recheck, .refresh, .eject, .removeAllDomains, .item, .list, .rename, .move,
      .delete, .changes, .workingSet:
      false
    }
  }

  /// A name a client may give an item: one path component, never a partial's or a backup's. A
  /// listing hides those and deletes abandoned ones, so the agent never creates one under a
  /// client's name.
  static func creatable(_ name: String) throws(TransportError) -> String {
    guard let validated = try RemotePath.root.appending(name).name,
      !SafeWriter.isPartial(validated), !SafeWriter.isBackup(validated)
    else { throw .invalidName(name) }
    return validated
  }
}
