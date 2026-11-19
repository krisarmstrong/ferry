import DeviceKit
import FerryIPC
import Foundation
import Observation

/// One device's Device Info sheet: it asks the agent once, which reads the device without
/// changing anything, and shows what came back. Copy puts the rows on the pasteboard as text.
@Observable @MainActor final class DeviceInfoSession {
  enum State: Equatable {
    case loading
    case loaded(AndroidDeviceInfo)
    case failed(String)
  }

  let device: DeviceID
  private let client: any AgentSending
  private let services: any SystemServicing

  private(set) var state = State.loading

  init(device: DeviceID, client: any AgentSending, services: any SystemServicing) {
    self.device = device
    self.client = client
    self.services = services
  }

  func load() async {
    state = .loading
    do {
      switch try await client.send(.deviceInfo(device), file: nil) {
      case .deviceInfo(let info):
        state = .loaded(info)
      case .toolFailed(let failure):
        state = .failed(DevicePresentation.message(for: failure))
      case .failure(let error):
        state = .failed(DevicePresentation.message(for: error))
      default:
        state = .failed(DevicePresentation.message(for: .io("unexpected reply")))
      }
    } catch {
      state = .failed(DevicePresentation.message(for: error))
    }
  }

  /// One `Label: value` line per row, as shown.
  func copy() {
    guard case .loaded(let info) = state else { return }
    services.copy(
      DevicePresentation.infoRows(info).map { "\($0.label): \($0.value)" }.joined(separator: "\n"))
  }
}
