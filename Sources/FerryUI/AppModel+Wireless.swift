import DeviceKit
import FerryIPC
import Foundation

/// The network forms that open in place under the menu's network rows.
public enum WirelessForm: Hashable, Sendable {
  /// Connect by Address: for devices that accept ADB over the network.
  case address
  /// Pair with Code: Android 11+ Wireless debugging.
  case code
}

/// The network form open in the menu and what was typed in it. It lives on the model, so the
/// menu's redraws every 2 s and its closing keep it.
struct NetworkForm: Equatable {
  let kind: WirelessForm
  /// Connect by Address: an IP address or hostname, with an optional port. Pair with Code: the
  /// IP address with the port the device shows.
  var address = ""
  /// The six-digit pairing code; Connect by Address has none.
  var code = ""
  /// Sent, and waiting for the agent.
  var isSending = false
  /// Why the last send failed, shown under the fields. It can carry adb's words, so it is shown
  /// verbatim.
  var message: MenuNotice?

  /// What the fields send, once they hold an address (and a code); the agent checks them again.
  var request: AgentRequest? {
    switch kind {
    case .address:
      return WirelessEndpoint(parsing: address).map(AgentRequest.connectAddress)
    case .code:
      guard let endpoint = WirelessEndpoint(parsing: address, defaultPort: nil),
        endpoint.isAddressLiteral, let code = PairingCode(code)
      else { return nil }
      return .pair(endpoint, code: code)
    }
  }

  var canSend: Bool { !isSending && request != nil }
}

/// What a network request said for the user, and whether it ends the form: connected, or the
/// rest is up to the user at the device.
struct WirelessReply: Sendable {
  let message: MenuNotice?
  let done: Bool
}

/// Reaching devices over the network: the Connect by Address and Pair with Code forms, Use over
/// Wi-Fi on a device on USB debugging, and remembered devices.
extension AppModel {
  /// Opens a form, closing the other, or closes it if it is open. From then on the menu offers
  /// adb if it is missing.
  public func toggleNetworkForm(_ kind: WirelessForm) {
    let opening = networkForm?.kind != kind
    closeNetworkForm()
    guard opening else { return }
    networkForm = NetworkForm(kind: kind)
    wantsNetwork = true
  }

  /// Escape, or the form's row clicked again: the form goes, with what it was sending and what
  /// it last said.
  func closeNetworkForm() {
    networkSend?.cancel()
    networkSend = nil
    networkForm = nil
  }

  /// Sends the open form. Done, it closes and the menu's status row says what follows (waiting
  /// for Allow on the device); otherwise it stays, with the reason under its fields. The form
  /// shows only its own answers: Use over Wi-Fi and the rest speak in the status row.
  func submitNetworkForm() async {
    guard let form = networkForm, form.canSend, let request = form.request else { return }
    networkForm?.isSending = true
    networkForm?.message = nil
    let send = Task { await wirelessReply(request) }
    networkSend = send
    let reply = await send.value
    // Collapsed or replaced meanwhile: the answer is not this form's.
    if networkSend == send {
      networkSend = nil
      if reply.done {
        networkForm = nil
        wirelessMessage = reply.message
      } else {
        networkForm?.isSending = false
        networkForm?.message = reply.message
      }
    }
    await refresh()
  }

  public func isRemembered(_ id: DeviceID) -> Bool {
    remembered.contains { $0.id == id }
  }

  /// The address the menu shows under a device on Wi-Fi: the one adb is connected on, or else
  /// where Ferry last reached it, for a device adb reaches by name.
  func wirelessAddress(of id: DeviceID) -> WirelessEndpoint? {
    connectedAddresses[id] ?? remembered.first { $0.id == id }?.addresses.first
  }

  /// Remembered devices not attached now, which get their own row with Connect and Forget.
  public var rememberedOffline: [RememberedDevice] {
    let attached = Set(devices.map(\.id))
    return remembered.filter { !attached.contains($0.id) }
  }

  public func useOverWiFi(_ id: DeviceID) async {
    await performWireless(.enableWireless(id))
  }

  public func connectAgain(_ id: DeviceID) async {
    await performWireless(.connectWireless(id))
  }

  /// Use It: the address is the device the menu showed, sent back as shown.
  public func confirm(_ shown: UnconfirmedAddress) async {
    await performWireless(.confirmWireless(shown))
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
  private func performWireless(_ request: AgentRequest) async {
    wirelessMessage = await wirelessReply(request).message
    await refresh()
  }

  private func wirelessReply(_ request: AgentRequest) async -> WirelessReply {
    do {
      switch try await client.send(request, file: nil) {
      case .wireless(let outcome):
        return WirelessReply(
          message: DevicePresentation.notice(for: outcome), done: outcome.endsTheForm)
      case .failure(let error):
        return WirelessReply(message: DevicePresentation.notice(for: error), done: false)
      default:
        return WirelessReply(
          message: DevicePresentation.notice(for: .io("unexpected reply")), done: false)
      }
    } catch {
      return WirelessReply(message: DevicePresentation.notice(for: error), done: false)
    }
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
