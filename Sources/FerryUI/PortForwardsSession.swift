import DeviceKit
import FerryIPC
import Foundation
import Observation

/// One device's Port Forwarding, in its expansion: the forwards adb holds for it, adding one
/// and removing one. A port is checked here before anything is sent (the agent checks again),
/// and an error is shown where the user is looking, in adb's words when adb refused.
@Observable @MainActor final class PortForwardsSession {
  let device: DeviceID
  private let client: any AgentSending

  private(set) var forwards: [PortForward] = []
  /// The port on this Mac and the port on the device, as typed.
  var localPort = ""
  var remotePort = ""
  private(set) var error: MenuNotice?
  private(set) var isBusy = false

  init(device: DeviceID, client: any AgentSending) {
    self.device = device
    self.client = client
  }

  func refresh() async {
    isBusy = true
    defer { isBusy = false }
    do {
      switch try await client.send(.forwards(device), file: nil) {
      case .forwards(let list):
        forwards = list
        error = nil
      case let other:
        error = Self.message(for: other)
      }
    } catch {
      self.error = DevicePresentation.notice(for: error)
    }
  }

  /// Return can call it while a request is on its way: one request at a time, as the buttons.
  func add() async {
    guard !isBusy else { return }
    guard let forward = parsed(), forward.isAllowed else {
      error = DevicePresentation.notice(for: .invalidPort)
      return
    }
    guard await send(.addForward(device, forward)) else { return }
    localPort = ""
    remotePort = ""
    await refresh()
  }

  func remove(_ forward: PortForward) async {
    guard await send(.removeForward(device, local: forward.local)) else { return }
    await refresh()
  }

  private func parsed() -> PortForward? {
    guard let local = UInt16(localPort.trimmingCharacters(in: .whitespaces)),
      let remote = UInt16(remotePort.trimmingCharacters(in: .whitespaces))
    else { return nil }
    return PortForward(local: local, remote: remote)
  }

  /// Whether the agent did it; if not, the error says why.
  private func send(_ request: AgentRequest) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      let response = try await client.send(request, file: nil)
      guard response == .done else {
        error = Self.message(for: response)
        return false
      }
      error = nil
      return true
    } catch {
      self.error = DevicePresentation.notice(for: error)
      return false
    }
  }

  private static func message(for response: AgentResponse) -> MenuNotice {
    switch response {
    case .toolFailed(let failure): DevicePresentation.notice(for: failure)
    case .failure(let error): DevicePresentation.notice(for: error)
    default: DevicePresentation.notice(for: .io("unexpected reply"))
    }
  }
}
