import DeviceKit
import Foundation

/// Test controls: injected failures and the device's contents.
extension FakeDevice {
  /// After the next `skipping` uploads, the next one stores its first `afterBytes` bytes, then
  /// throws `error`.
  public func failUpload(afterBytes: UInt64, with error: TransportError, skipping: Int = 0) {
    uploadFailure = UploadFailure(
      skipping: skipping, afterBytes: afterBytes, error: error, disconnects: false)
  }

  /// After the next `skipping` uploads, the next one stores its first `afterBytes` bytes and the
  /// device goes away, as when the cable is pulled mid-transfer: nothing more reaches it, not
  /// even the clean-up of what it kept.
  public func disconnectDuringUpload(afterBytes: UInt64, skipping: Int = 0) {
    uploadFailure = UploadFailure(
      skipping: skipping, afterBytes: afterBytes, error: .deviceDisconnected, disconnects: true)
  }

  /// The failure the upload starting now meets, if any, counting down the uploads it skips.
  func nextUploadFailure() -> UploadFailure? {
    guard var failure = uploadFailure else { return nil }
    if failure.skipping > 0 {
      failure.skipping -= 1
      uploadFailure = failure
      return nil
    }
    uploadFailure = nil
    return failure
  }

  struct DownloadFailure {
    var skipping: Int
    let afterBytes: UInt64
    /// `nil`: the download reports success with only what arrived.
    let error: TransportError?
  }

  /// After the next `skipping` downloads, the next one writes its first `afterBytes` bytes to the
  /// Mac, then throws `error`.
  public func failDownload(afterBytes: UInt64, with error: TransportError, skipping: Int = 0) {
    downloadFailure = DownloadFailure(skipping: skipping, afterBytes: afterBytes, error: error)
  }

  /// The next download delivers only its first `bytes` bytes and reports itself done, as a
  /// transport that loses the end of a file without noticing.
  public func shortenNextDownload(to bytes: UInt64) {
    downloadFailure = DownloadFailure(skipping: 0, afterBytes: bytes, error: nil)
  }

  func nextDownloadFailure() -> DownloadFailure? {
    guard var failure = downloadFailure else { return nil }
    if failure.skipping > 0 {
      failure.skipping -= 1
      downloadFailure = failure
      return nil
    }
    downloadFailure = nil
    return failure
  }

  /// Runs `hook` when the next download starts, as the device going away mid-transfer.
  public func onNextDownload(_ hook: @escaping @Sendable () async -> Void) {
    downloadHook = hook
  }

  func runDownloadHook() async {
    guard let hook = downloadHook else { return }
    downloadHook = nil
    await hook()
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

  /// Runs `hook` when the next upload starts, as an app on the device changing files while the
  /// upload goes up.
  func setMethod(_ method: ConnectionMethod) {
    self.method = method
  }

  public func onNextUpload(_ hook: @escaping @Sendable () async -> Void) {
    uploadHook = hook
  }

  /// Runs `hook` when the next move starts, as a device that stops answering mid-move.
  public func onNextMove(_ hook: @escaping @Sendable () async -> Void) {
    moveHook = hook
  }

  /// Runs `hook` when the next delete starts, as an app on the device adding files meanwhile.
  public func onNextDelete(_ hook: @escaping @Sendable () async -> Void) {
    deleteHook = hook
  }

  func runDeleteHook() async {
    guard let hook = deleteHook else { return }
    deleteHook = nil
    await hook()
  }

  func runUploadHook() async {
    guard let hook = uploadHook else { return }
    uploadHook = nil
    await hook()
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
