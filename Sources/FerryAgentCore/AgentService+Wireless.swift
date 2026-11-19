import DeviceKit
import FerryIPC

extension AgentService {
  /// Answers the app's network requests; `nil` for any other. Without adb they fail as adb
  /// being unavailable, which is what the user can act on.
  func performWirelessRequest(_ request: AgentRequest) async -> AgentResponse? {
    let outcome: WirelessOutcome?
    switch request {
    case .forgetWireless(let id):
      await wireless?.forget(id)
      return .done
    case .ignoreWireless(let address):
      await wireless?.ignore(address)
      return .done
    case .connectAddress(let address): outcome = await wireless?.connect(address)
    case .pair(let address, let code): outcome = await wireless?.pair(address, code: code)
    case .connectWireless(let id): outcome = await wireless?.reconnect(id)
    case .enableWireless(let id):
      guard let wireless else { return .wireless(.failed(.adbUnavailable)) }
      // It restarts the device's adbd, which would cut off whatever runs on it: refused while
      // a tool or a transfer runs, and transfers that start meanwhile wait for it.
      guard await tools?.isBusy(id) != true, await transfers.beginRestart(id) else {
        return .wireless(.failed(.deviceInUse))
      }
      outcome = await wireless.useOverWiFi(id)
      await transfers.endRestart(id)
    case .confirmWireless(let shown): outcome = await wireless?.confirm(shown)
    default: return nil
    }
    return .wireless(outcome ?? .failed(.adbUnavailable))
  }

}
