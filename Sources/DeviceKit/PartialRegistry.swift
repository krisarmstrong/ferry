import Foundation

/// Partials still being written, and backups this session made, so a concurrent listing leaves
/// them alone. One per session; see `DeviceSession.partials`.
public actor PartialRegistry {
  private struct Entry: Hashable {
    let storage: StorageID
    let path: RemotePath
  }

  private var inFlight: Set<Entry> = []
  private var backups: Set<Entry> = []
  /// Local backups (see `ReplaceBackups`) a write or a listing is using now.
  private var localBackupsInUse: Set<UUID> = []
  /// Local backups whose name holds another file: left alone for the rest of the session.
  private var localBackupsKept: Set<UUID> = []
  /// Files a failed replace put back, each with the file it was before: a copy of the same
  /// bytes, but dated when it went back.
  private var restored: [Entry: (restored: RemoteItem, original: RemoteItem)] = [:]

  public init() {}

  public func registerInFlight(_ path: RemotePath, in storage: StorageID) {
    inFlight.insert(Entry(storage: storage, path: path))
  }

  public func unregisterInFlight(_ path: RemotePath, in storage: StorageID) {
    inFlight.remove(Entry(storage: storage, path: path))
  }

  public func contains(_ path: RemotePath, in storage: StorageID) -> Bool {
    inFlight.contains(Entry(storage: storage, path: path))
  }

  /// Whether a partial is being written in `folder`, so a replace there may be using a backup.
  public func hasWriteInFlight(in folder: RemotePath, storage: StorageID) -> Bool {
    inFlight.contains { $0.storage == storage && $0.path.parent == folder }
  }

  public func recordBackup(_ path: RemotePath, in storage: StorageID) {
    backups.insert(Entry(storage: storage, path: path))
  }

  /// Whether this session made the backup at `path`.
  public func isSessionBackup(_ path: RemotePath, in storage: StorageID) -> Bool {
    backups.contains(Entry(storage: storage, path: path))
  }

  /// Takes backup `id` for the caller; `false` if another holds it or it is kept.
  public func claimLocalBackup(_ id: UUID) -> Bool {
    guard !localBackupsKept.contains(id) else { return false }
    return localBackupsInUse.insert(id).inserted
  }

  public func releaseLocalBackup(_ id: UUID) {
    localBackupsInUse.remove(id)
  }

  public func keepLocalBackup(_ id: UUID) {
    localBackupsKept.insert(id)
  }

  public func recordRestore(_ item: RemoteItem, of original: RemoteItem, in storage: StorageID) {
    restored[Entry(storage: storage, path: item.path)] = (item, original)
  }

  /// The file `item` was before a failed replace put it back, if it is such a file and has not
  /// changed since. The two hold the same bytes, so a save based on the original still applies.
  public func original(ofRestored item: RemoteItem, in storage: StorageID) -> RemoteItem? {
    guard let entry = restored[Entry(storage: storage, path: item.path)],
      item.matches(entry.restored)
    else { return nil }
    return entry.original
  }
}
