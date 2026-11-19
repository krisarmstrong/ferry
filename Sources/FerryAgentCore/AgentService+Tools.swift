import DeviceKit
import FerryIPC

extension AgentService {
  /// Answers the tool requests; `nil` for any other. Without adb they fail as the device not
  /// being served over ADB, which the menu already explains.
  func performToolRequest(
    _ request: AgentRequest, file: Int32?, progress: @escaping TransferProgressHandler,
    logs: LogSink?
  ) async throws(TransportError) -> AgentResponse? {
    if let response = try await performDeveloperRequest(request, logs: logs) { return response }
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
    case (.screenshot(let id), let file?):
      guard let tools else { return .toolFailed(.notOverADB) }
      outcome = try await tools.screenshot(id, into: file)
    case (.startRecording(let id), _):
      guard let tools else { return .toolFailed(.notOverADB) }
      outcome = try await tools.startRecording(id)
    case (.stopRecording(let id), _):
      guard let tools else { return .toolFailed(.notRecording) }
      outcome = try await tools.stopRecording(id)
    case (.saveRecording(let id), let file?):
      guard let tools else { return .toolFailed(.notRecording) }
      outcome = try await tools.saveRecording(id, into: file)
    case (.discardRecording(let id), _):
      guard let tools else { return .toolFailed(.notRecording) }
      outcome = try await tools.discardRecording(id)
    default:
      return nil
    }
    return outcome.response
  }
}

extension AgentService {
  /// Logcat, port forwards, device info and the shell's target; `nil` for any other request.
  func performDeveloperRequest(_ request: AgentRequest, logs: LogSink?)
    async throws(TransportError) -> AgentResponse?
  {
    switch request {
    case .startLogcat(let id, let stream):
      // The lines go to the client that asked: with no way to send them there is no stream.
      guard let logs else { throw .io(String(localized: AgentText.badRequest)) }
      guard let tools else { return .toolFailed(.notOverADB) }
      return try await tools.streamLogcat(id, stream: stream, to: logs).response
    case .stopLogcat(let id, let stream):
      return await tools?.stopLogcat(id, stream: stream).response ?? .done
    case .forwards(let id):
      guard let tools else { return .toolFailed(.notOverADB) }
      switch try await tools.forwards(id) {
      case .success(let list): return .forwards(list)
      case .failure(let failure): return .toolFailed(failure)
      }
    case .addForward(let id, let forward):
      guard let tools else { return .toolFailed(.notOverADB) }
      return try await tools.addForward(id, forward).response
    case .removeForward(let id, let local):
      guard let tools else { return .toolFailed(.notOverADB) }
      return try await tools.removeForward(id, local: local).response
    case .deviceInfo(let id):
      guard let tools else { return .toolFailed(.notOverADB) }
      switch try await tools.deviceInfo(id) {
      case .success(let info): return .deviceInfo(info)
      case .failure(let failure): return .toolFailed(failure)
      }
    case .shellTarget(let id):
      guard let tools else { return .toolFailed(.notOverADB) }
      switch try await tools.shellTarget(id) {
      case .success(let target): return .shellTarget(target)
      case .failure(let failure): return .toolFailed(failure)
      }
    default:
      return nil
    }
  }
}
