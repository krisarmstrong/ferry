/// What the agent can do with an attached device right now.
public enum DeviceState: Sendable, Equatable, Codable {
  case ready([StorageInfo])
  /// Attached, but file transfer is off on the device, or Ferry ejected it.
  case notSharingFiles
  /// Another app holds the device.
  case busy
  case failed(TransportError)
}

public struct AttachedDevice: Sendable, Equatable, Codable, Identifiable {
  public let info: DeviceInfo
  public let state: DeviceState

  public var id: DeviceID { info.id }

  public init(info: DeviceInfo, state: DeviceState) {
    self.info = info
    self.state = state
  }
}
