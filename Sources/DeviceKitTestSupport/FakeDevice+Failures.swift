import DeviceKit
import Foundation

/// Test controls: injected failures and the device's contents.
extension FakeDevice {
  /// The next upload stores its first `afterBytes` bytes, then throws `error`.
  public func failUpload(afterBytes: UInt64, with error: TransportError) {
    uploadFailure = (afterBytes, error)
  }

  /// Uploads keep only the first `bytes` bytes and report success. `nil` turns this off.
  public func truncateUploads(to bytes: UInt64?) {
    uploadTruncation = bytes
  }

  /// After the next `skipping` renames, `count` renames throw `error`. `nil` clears a pending
  /// failure.
  public func failRename(with error: TransportError?, skipping: Int = 0, count: Int = 1) {
    renameFailure = error.map { RenameFailure(skipping: skipping, remaining: count, error: $0) }
  }

  /// Every backup a rename sets aside is stored as `actual`, as a FAT card or 7-bit firmware
  /// would, and the rename reports the change.
  public func storeBackups(as actual: String) {
    backupStoredAs = actual
  }

  /// The device lists the file at `path` as `size` bytes, whatever it holds.
  public func reportSize(_ size: UInt64, for path: RemotePath) {
    reportedSizes[path] = size
  }

  /// The next `storages()` throws `error`.
  public func failNextStorages(with error: TransportError) {
    storagesFailure = error
  }

  /// Every `storages()` throws `error` until this is called with `nil`.
  public func failStorages(with error: TransportError?) {
    storagesFailing = error
  }

  /// The next `list(_:in:)` throws `error`. `nil` clears a pending failure.
  public func failList(with error: TransportError?) {
    listFailure = error
  }

  /// The next delete throws `error`.
  public func failNextDelete(with error: TransportError) {
    deleteFailure = error
  }

  /// The same storages and contents as a new session would see them: a new device object with
  /// its own partials registry, as after a replug or an agent restart.
  public func newSession() async -> FakeDevice {
    let device = FakeDevice(info: info, storages: storageInfos, capabilities: deviceCapabilities)
    await device.adopt(tree)
    return device
  }

  func adopt(_ contents: [StorageID: [RemotePath: Node]]) {
    tree = contents
  }

  public func contents(of path: RemotePath, in storage: StorageID) -> Data? {
    if case .file(let data, _) = tree[storage]?[path] { return data }
    return nil
  }

  public func allPaths(in storage: StorageID) -> [RemotePath] {
    (tree[storage] ?? [:]).keys.sorted { $0.description < $1.description }
  }
}
