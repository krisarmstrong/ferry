public enum TransportError: Error, Equatable, Sendable {
  case deviceNotFound(DeviceID)
  case deviceBusy
  case deviceLocked
  case deviceDisconnected
  case notFound(RemotePath)
  case alreadyExists(RemotePath)
  case invalidName(String)
  case unsupported(String)
  case insufficientSpace(needed: UInt64, free: UInt64)
  case fileTooLargeForStorage(size: UInt64)
  case sizeMismatch(expected: UInt64, actual: UInt64)
  case cancelled
  case io(String)
}
