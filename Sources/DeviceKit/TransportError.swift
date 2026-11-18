import os

public enum TransportError: Error, Equatable, Sendable, Codable {
  case noDeviceConnected
  case deviceNotFound(DeviceID)
  case noStorage
  /// Carries the storage's description when picked by the user, else its `StorageID.key`.
  case storageNotFound(String)
  case deviceBusy
  case deviceLocked
  case deviceDisconnected
  case notFound(RemotePath)
  /// An item identifier the agent does not know: the item was deleted, or its domain removed.
  case unknownItem
  case alreadyExists(RemotePath)
  case invalidName(String)
  case unsupported(String)
  case insufficientSpace(needed: UInt64, free: UInt64)
  case fileTooLargeForStorage(size: UInt64)
  case sizeMismatch(expected: UInt64, actual: UInt64)
  /// A download brought fewer or more bytes than the device listed for the file.
  case downloadSizeMismatch(listed: UInt64, received: UInt64)
  /// The device stored the object under a name other than the one it was sent (a FAT card's
  /// de-duplication, 7-bit firmware, truncation).
  case nameChangedByDevice(requested: String, actual: String)
  /// A folder asked to be deleted on its own still holds items.
  case directoryNotEmpty(RemotePath)
  /// The device's copy of the file changed since the version the request was based on.
  case changedOnDevice(RemotePath)
  /// The Mac's own volume has no room for a copy of the file.
  case macDiskFull(needed: UInt64, free: UInt64)
  case cancelled
  case io(String)
}

extension TransportError {
  /// How a failed call is logged: a cancel is the user's own doing, not a fault.
  public var logType: OSLogType {
    self == .cancelled ? .info : .error
  }
}
