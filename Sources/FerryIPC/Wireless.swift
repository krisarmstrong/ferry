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

/// An address that answered as a device Ferry already knows, by USB or at another address. A
/// serial over plain TCP proves nothing, so the agent dropped the connection and waits for the
/// user to say the address is that device.
public struct UnconfirmedAddress: Codable, Sendable, Equatable, Hashable {
  public let address: WirelessEndpoint
  public let id: DeviceID
  /// The model of the device it claims to be, as Ferry knows it.
  public let name: String

  public init(address: WirelessEndpoint, id: DeviceID, name: String) {
    self.address = address
    self.id = id
    self.name = name
  }
}

/// How a request to reach a device over the network ended.
public enum WirelessOutcome: Codable, Sendable, Equatable {
  /// adb lists the device and the agent remembers it.
  case connected
  /// The device was reached and asks the user to allow this Mac. It is remembered once allowed.
  case awaitingAllow(WirelessEndpoint)
  /// The address answered as a device Ferry already knows: dropped until the user confirms it.
  case needsConfirmation(WirelessEndpoint)
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
  /// The device did not say who it is (no serial number), so it was disconnected.
  case unidentified
  /// Pairing was given a name; it needs the IP address the device shows.
  case pairingNeedsAddress
  /// The address no longer stands for the device the menu showed; the menu has the current offer.
  case offerChanged
  /// Use over Wi-Fi restarts the device's adb, which would cut off a transfer, a screen recording
  /// or a log stream running on it.
  case deviceInUse
  /// adb found no route to the device, and macOS denies Ferry the local network (TN3179).
  case localNetworkDenied
  /// adb's server had lost the network (an earlier agent's, left running), so Ferry replaced it,
  /// and the new one was not up in time to try again.
  case serverRestarted
  /// adb's own words, one line.
  case adb(String)
}
