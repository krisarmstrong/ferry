import DeviceKit
import Foundation

/// The object-ID operations `MTPSession` builds on. `MTPDevice` is the real one; the seam exists
/// so the session's path rules are testable without a phone.
protocol MTPDeviceOperations: Sendable {
  var info: DeviceInfo { get }
  func capabilities() async -> DeviceCapabilities
  func storages() async throws(TransportError) -> [(raw: UInt32, info: StorageInfo)]
  func list(storage: UInt32, parent: UInt32) async throws(TransportError) -> [MTPEntry]
  func download(objectID: UInt32, to file: URL, progress: ProgressHandler)
    async throws(TransportError)
  func upload(
    from file: URL, name: String, parent: UInt32, storage: UInt32, progress: ProgressHandler
  ) async throws(TransportError) -> UInt32
  func createFolder(name: String, parent: UInt32, storage: UInt32) async throws(TransportError)
    -> UInt32
  func rename(objectID: UInt32, to name: String) async throws(TransportError)
  func move(objectID: UInt32, storage: UInt32, newParent: UInt32) async throws(TransportError)
  func delete(objectID: UInt32) async throws(TransportError)
  func metadata(objectID: UInt32) async throws(TransportError) -> MTPEntry
  /// Closes the device and opens it again, which drops libmtp's object cache.
  func reopen() async throws(TransportError)
  func close() async
}

extension MTPDevice: MTPDeviceOperations {}
