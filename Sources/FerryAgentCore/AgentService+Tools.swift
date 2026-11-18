import DeviceKit
import FerryIPC

extension AgentService {
  /// Answers the tool requests; `nil` for any other. Without adb they fail as the device not
  /// being served over ADB, which the menu already explains.
  func performToolRequest(
    _ request: AgentRequest, file: Int32?, progress: @escaping TransferProgressHandler
  ) async throws(TransportError) -> AgentResponse? {
    let outcome: ADBTools.Outcome
    switch (request, file) {
    case (.installAPK(let id, let name), let file?):
      let name = try Self.creatable(name)
      guard let tools else { return .toolFailed(.notOverADB) }
      // Listed as a transfer while the app goes to the device, so the menu shows its progress.
      let start = ActiveTransfer(
        device: id, name: name, direction: .toDevice, completed: 0, total: 0)
      let install = { (handler: @escaping ProgressHandler) async throws(TransportError) in
        try await tools.installAPK(file, on: id, progress: handler)
      }
      outcome = try await transfers.track(start, report: progress, install)
    case (.screenshot(let id), _):
      guard let tools else { return .toolFailed(.notOverADB) }
      outcome = try await tools.screenshot(id)
    case (.startRecording(let id), _):
      guard let tools else { return .toolFailed(.notOverADB) }
      outcome = try await tools.startRecording(id)
    case (.stopRecording(let id), _):
      guard let tools else { return .toolFailed(.notRecording) }
      outcome = try await tools.stopRecording(id)
    default:
      return nil
    }
    return outcome.response
  }
}
