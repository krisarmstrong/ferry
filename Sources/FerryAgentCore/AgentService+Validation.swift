import DeviceKit
import FerryIPC
import Foundation

// MARK: Validating requests

extension AgentService {
  /// Throws `.directoryNotEmpty(folder)` unless the agent has reported to FileProvider everything
  /// Finder would show in the device folder `folder`, walked fresh: a recursive delete takes only
  /// what the user saw go, never what the device added since. Each item not reported is recorded
  /// now, so FileProvider, which puts the folder back on that error, shows it there. A tree with
  /// an item more than `RemotePath.maxTreeDepth` levels below `folder`, or more than
  /// `deleteWalkLimit` items, is refused the same way, unwalked past that point. The listings
  /// also reap abandoned partials.
  static func requireSeen(_ folder: RemotePath, on route: DomainController.Route)
    async throws(TransportError)
  {
    var pending = [(folder, 1)]
    var walked = 0
    var unseen: [RemoteItem] = []
    while let (current, depth) = pending.popLast() {
      for child in try await route.writer.visibleList(current, in: route.storage) {
        walked += 1
        guard walked <= deleteWalkLimit, depth <= RemotePath.maxTreeDepth else {
          throw .directoryNotEmpty(folder)
        }
        if await !route.items.reported(child.path) { unseen.append(child) }
        if child.kind == .folder { pending.append((child.path, depth + 1)) }
      }
    }
    guard !unseen.isEmpty else { return }
    // Parents first, so each item's parent has its identifier when it is recorded.
    for item in unseen.sorted(by: { $0.path.components.count < $1.path.components.count }) {
      _ = await route.items.observed(item)
    }
    throw .directoryNotEmpty(folder)
  }

  static let deleteWalkLimit = 100_000

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
  static func creatable(_ name: String) throws(TransportError) -> String {
    guard let validated = try RemotePath.root.appending(name).name,
      !SafeWriter.isPartial(validated), !SafeWriter.isBackup(validated)
    else { throw .invalidName(name) }
    return validated
  }
}
