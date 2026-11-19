import DeviceKit

/// A device as the Finder Sync extension sees it: enough to offer Send and Install, and nothing
/// of the status report it has no use for.
public struct DeviceSummary: Codable, Sendable, Equatable {
  public let id: DeviceID
  /// What the device goes by (`DeviceInfo.name`), as the device supplied it: escape it to show.
  public let name: String
  public let method: ConnectionMethod
  /// Whether a file can go to the device now: it is ready and its internal storage has its
  /// Finder location.
  public let ready: Bool

  public init(id: DeviceID, name: String, method: ConnectionMethod, ready: Bool) {
    self.id = id
    self.name = name
    self.method = method
    self.ready = ready
  }
}
