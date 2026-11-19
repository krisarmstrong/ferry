/// A TCP port forward adb holds for a device: connections to `local` on the Mac reach `remote`
/// on the device.
public struct PortForward: Codable, Sendable, Hashable {
  public let local: UInt16
  public let remote: UInt16

  public init(local: UInt16, remote: UInt16) {
    self.local = local
    self.remote = remote
  }

  /// The lowest port a forward may listen on: below it the Mac reserves ports for the system.
  public static let lowestLocalPort: UInt16 = 1024

  /// Whether Ferry may add this forward: a Mac port from 1024 up, any device port, neither 0.
  public var isAllowed: Bool {
    local >= Self.lowestLocalPort && remote >= 1
  }
}

/// What a device says about itself, for the Device Info sheet. Every string was written by the
/// device, so a screen shows it escaped.
public struct AndroidDeviceInfo: Codable, Sendable, Equatable {
  public enum BatteryState: String, Codable, Sendable {
    case charging, discharging, notCharging, full, unknown
  }

  public struct Battery: Codable, Sendable, Equatable {
    /// Percent, 0...100.
    public let level: Int
    public let state: BatteryState

    public init(level: Int, state: BatteryState) {
      self.level = level
      self.state = state
    }
  }

  public struct Storage: Codable, Sendable, Equatable {
    public let used: UInt64
    public let free: UInt64

    public init(used: UInt64, free: UInt64) {
      self.used = used
      self.free = free
    }
  }

  public let model: String
  public let androidVersion: String
  public let build: String
  public let serial: String
  public let battery: Battery?
  /// Ethernet and Wi-Fi IPv4 addresses, never the loopback or dummy interfaces.
  public let addresses: [String]
  /// Internal shared storage.
  public let storage: Storage?

  public init(
    model: String, androidVersion: String, build: String, serial: String, battery: Battery?,
    addresses: [String], storage: Storage?
  ) {
    self.model = model
    self.androidVersion = androidVersion
    self.build = build
    self.serial = serial
    self.battery = battery
    self.addresses = addresses
    self.storage = storage
  }
}
