/// What the agent can do with an attached device right now.
public enum DeviceState: Sendable, Equatable, Codable {
  case ready([StorageInfo])
  /// Attached, but file transfer is off on the device.
  case notSharingFiles
  /// The user ejected it: attached, left alone until the user mounts it again or unplugs it.
  case ejected
  /// Another app holds the device.
  case busy
  case failed(TransportError)
}

public struct AttachedDevice: Sendable, Equatable, Codable, Identifiable {
  public let info: DeviceInfo
  public let state: DeviceState
  /// How Ferry reaches the device: for a ready one, the method its session uses.
  public let method: ConnectionMethod

  public var id: DeviceID { info.id }

  public init(info: DeviceInfo, state: DeviceState, method: ConnectionMethod) {
    self.info = info
    self.state = state
    self.method = method
  }
}
