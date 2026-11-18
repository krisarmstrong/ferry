import DeviceKit

public enum HubEvent: Sendable, Equatable {
  /// A device the hub had not listed. Emitted once per device until it is detached.
  case attached(AttachedDevice)
  case changed(AttachedDevice)
  case detached(DeviceID)
}
