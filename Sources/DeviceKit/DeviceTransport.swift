import Foundation

/// Reports bytes transferred so far and the total. Return `false` to cancel the transfer.
public typealias ProgressHandler = @Sendable (_ done: UInt64, _ total: UInt64) -> Bool

public protocol DeviceTransport: Sendable {
  func connectedDevices() async throws(TransportError) -> [DeviceInfo]
  func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession
}

public protocol DeviceSession: Sendable {
  var info: DeviceInfo { get }
  func capabilities() async -> DeviceCapabilities
  /// A device that reports no storages is locked, so implementations throw `.deviceLocked`.
  func storages() async throws(TransportError) -> [StorageInfo]
  func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  func item(at path: RemotePath, in storage: StorageID) async throws(TransportError) -> RemoteItem
  func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, progress: ProgressHandler
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
