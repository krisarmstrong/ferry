import DeviceKit

/// A device the agent reconnects over the network: when it starts, when adb's server comes back,
/// and when adb's mDNS lists it.
public struct RememberedDevice: Codable, Sendable, Equatable, Identifiable {
  public let id: DeviceID
  /// The model as the device reported it when it was remembered.
  public let name: String
  /// Where it was last reached, most recent first.
  public let addresses: [WirelessEndpoint]

  public init(id: DeviceID, name: String, addresses: [WirelessEndpoint]) {
    self.id = id
    self.name = name
    self.addresses = addresses
  }
}

/// How a request to reach a device over the network ended.
public enum WirelessOutcome: Codable, Sendable, Equatable {
  /// adb lists the device and the agent remembers it.
  case connected
  /// The device was reached and asks the user to allow this Mac. It is remembered once allowed.
  case awaitingAllow(WirelessEndpoint)
  /// The device on USB has no Ethernet or Wi-Fi address yet.
  case needsNetwork
  case failed(WirelessFailure)
}

public enum WirelessFailure: Codable, Sendable, Equatable {
  /// adb is not installed or its server does not answer.
  case adbUnavailable
  /// The device is not attached over USB with debugging allowed.
  case notOverUSB
  case notRemembered
  /// Paired, but adb's mDNS lists no connect service for it.
  case noConnectService
  /// The address answers as another device, so it was disconnected again.
  case otherDevice
  /// adb's own words, one line.
  case adb(String)
}
