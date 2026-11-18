import Foundation

/// Reports bytes transferred so far and the total. Return `false` to cancel the transfer.
public typealias ProgressHandler = @Sendable (_ done: UInt64, _ total: UInt64) -> Bool

public protocol DeviceTransport: Sendable {
  /// Finds attached devices. A device this process already holds is reported without being
  /// touched.
  func scan() async throws(TransportError) -> DeviceScan
  /// Opens a device the most recent `scan()` reported in `devices`. A device this process
  /// already holds is `.deviceBusy`.
  func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession
  /// Leaves the held device `id` alone after its session closes: scans report it in
  /// `notSharing` without touching it until it is unplugged or `unpark(_:)` is called.
  func park(_ id: DeviceID) async
  /// Lets the next scan try `id` again: a device reported busy, or one parked.
  func unpark(_ id: DeviceID) async
}

public protocol DeviceSession: Sendable {
  var info: DeviceInfo { get }
  /// Partials being written on this device. Shared by every `SafeWriter` over the session and
  /// by the session itself, so no listing reaps a partial that is still being written.
  var partials: PartialRegistry { get }
  func capabilities() async -> DeviceCapabilities
  /// A device that reports no storages is locked, so implementations throw `.deviceLocked`.
  func storages() async throws(TransportError) -> [StorageInfo]
  func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  func item(at path: RemotePath, in storage: StorageID) async throws(TransportError) -> RemoteItem
  /// Without `replacing`, a file already at `file` when the download completes is
  /// `.alreadyExists` and is left untouched.
  func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError)
  /// `path` must not already exist.
  func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem
  func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  /// Deleting a folder deletes its contents.
  func delete(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
  func close() async
}
