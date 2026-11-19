import DeviceKit
import FerryIPC
import Foundation

/// Reaching devices over the network: the Connect by Address and Pair with Code forms, Use over
/// Wi-Fi on a device on USB debugging, and remembered devices.
extension AppModel {
  /// Whether the form's address can be sent: an IP address or hostname, with an optional port.
  public static func isValidAddress(_ text: String) -> Bool {
    WirelessEndpoint(parsing: text) != nil
  }

  /// Pairing takes the IP address with the port the device shows, and its six-digit code.
  public static func isValidPairing(address: String, code: String) -> Bool {
    WirelessEndpoint(parsing: address, defaultPort: nil)?.isAddressLiteral == true
      && PairingCode(code) != nil
  }

  public func isRemembered(_ id: DeviceID) -> Bool {
    remembered.contains { $0.id == id }
  }

  /// Remembered devices not attached now, which get their own row with Connect and Forget.
  public var rememberedOffline: [RememberedDevice] {
    let attached = Set(devices.map(\.id))
    return remembered.filter { !attached.contains($0.id) }
  }

  /// Sends the address. Returns whether the form is done: connected, or waiting for the user to
  /// tap Allow on the device. An address that is not one sends nothing.
  public func connect(address: String) async -> Bool {
    guard let endpoint = WirelessEndpoint(parsing: address) else { return false }
    return await performWireless(.connectAddress(endpoint))
  }

  public func pair(address: String, code: String) async -> Bool {
    guard let endpoint = WirelessEndpoint(parsing: address, defaultPort: nil),
      let code = PairingCode(code)
    else { return false }
    return await performWireless(.pair(endpoint, code: code))
  }

  public func useOverWiFi(_ id: DeviceID) async {
    _ = await performWireless(.enableWireless(id))
  }

  public func connectAgain(_ id: DeviceID) async {
    _ = await performWireless(.connectWireless(id))
  }

  /// Use It: the address is the device the menu showed, sent back as shown.
  public func confirm(_ shown: UnconfirmedAddress) async {
    _ = await performWireless(.confirmWireless(shown))
  }

  /// Ignore: it is not.
  public func ignore(_ address: WirelessEndpoint) async {
    wirelessMessage = nil
    await perform(.ignoreWireless(address))
  }

  public func forget(_ id: DeviceID) async {
    wirelessMessage = nil
    await perform(.forgetWireless(id))
  }

  /// Sends a request answered with `.wireless`, keeps what it said for the user, and reads the
  /// status.
  private func performWireless(_ request: AgentRequest) async -> Bool {
    let done: Bool
    do {
      switch try await client.send(request, file: nil) {
      case .wireless(let outcome):
        wirelessMessage = DevicePresentation.message(for: outcome)
        done = outcome.endsTheForm
      case .failure(let error):
        wirelessMessage = DevicePresentation.message(for: error)
        done = false
      default:
        wirelessMessage = DevicePresentation.message(for: .io("unexpected reply"))
        done = false
      }
    } catch {
      wirelessMessage = DevicePresentation.message(for: error)
      done = false
    }
    await refresh()
    return done
  }
}

extension WirelessOutcome {
  /// Connected, or the rest is up to the user at the device.
  var endsTheForm: Bool {
    switch self {
    case .connected, .awaitingAllow, .needsConfirmation: true
    case .needsNetwork, .failed: false
    }
  }
}
