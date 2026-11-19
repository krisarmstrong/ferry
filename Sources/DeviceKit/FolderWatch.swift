/// A folder a device says changed: a hint to list it again, never a description of the change.
public struct FolderHint: Sendable, Hashable {
  public let storage: StorageID
  public let folder: RemotePath

  public init(storage: StorageID, folder: RemotePath) {
    self.storage = storage
    self.folder = folder
  }
}

extension DeviceSession {
  /// No watch: the device's changes are found by listing again.
  public func watch(_ folders: [FolderHint]) async -> AsyncStream<FolderHint>? { nil }
}
