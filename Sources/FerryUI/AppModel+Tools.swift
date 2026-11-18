import DeviceKit
import FerryIPC
import Foundation

/// An app the menu is installing.
public struct AppInstall: Sendable, Equatable {
  /// The file's name, as the user picked it.
  public let name: String
  /// Whole percent of the file on the device; installing follows at 100.
  public var percent: Int
}

/// The ADB tools: Install App…, a screenshot and a screen recording, for a device Ferry serves
/// over ADB. Screenshots and recordings are saved by the agent where macOS saves its own, and
/// shown in Finder.
extension AppModel {
  /// The device's recording: as the agent reports it, or as asked for until the agent answers.
  public func recording(on device: DeviceID) -> ActiveRecording? {
    recordings.first { $0.device == device }
      ?? requestedRecordings[device].map {
        ActiveRecording(device: device, started: $0, stopping: false)
      }
  }

  /// Install App…: asks for an `.apk`, then installs it.
  public func chooseAndInstallAPK(on device: DeviceID) async {
    guard let url = await services.chooseAPK() else { return }
    await installAPK(url, on: device)
  }

  /// Installs the `.apk` at `url`, sent to the agent as an open file. Anything else (a file
  /// dropped on the row) is not sent; the agent checks the contents again.
  public func installAPK(_ url: URL, on device: DeviceID) async {
    guard DevicePresentation.isAPK(url), installs[device] == nil else { return }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      actionError = DevicePresentation.message(for: .io(error.localizedDescription))
      return
    }
    defer { try? handle.close() }
    let name = url.lastPathComponent
    installs[device] = AppInstall(name: name, percent: 0)
    let progress: TransferProgressHandler = { [weak self] done, total in
      let percent = ActiveTransfer(
        device: device, name: name, direction: .toDevice, completed: done, total: total
      ).percent
      Task { @MainActor in self?.installs[device]?.percent = percent }
    }
    let response = await sendTool(.installAPK(device, name: name), file: handle, progress: progress)
    installs[device] = nil
    if response == .done { toolMessage = DevicePresentation.installedLine(name) }
    await refresh()
  }

  public func takeScreenshot(on device: DeviceID) async {
    _ = await sendTool(.screenshot(device), file: nil)
    await refresh()
  }

  /// Starts a recording. The agent answers once it is saved, after Stop or its time limit, and
  /// the file is shown then; meanwhile the status shows it running.
  public func startRecording(on device: DeviceID) async {
    guard recording(on: device) == nil else { return }
    requestedRecordings[device] = Date()
    _ = await sendTool(.startRecording(device), file: nil)
    requestedRecordings[device] = nil
    await refresh()
  }

  public func stopRecording(on device: DeviceID) async {
    _ = await sendTool(.stopRecording(device), file: nil)
    await refresh()
  }

  /// Sends a tool request and shows what it said: a saved file in Finder, a failure as the
  /// menu's error. Returns the response.
  private func sendTool(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler? = nil
  ) async -> AgentResponse? {
    preservedChanges = []
    toolMessage = nil
    do {
      let response = try await client.send(request, file: file, progress: progress)
      switch response {
      case .done:
        actionError = nil
      case .saved(let url):
        actionError = nil
        services.reveal([url])
      case .toolFailed(let failure):
        actionError = DevicePresentation.message(for: failure)
      case .failure(let error):
        actionError = DevicePresentation.message(for: error)
      default:
        actionError = DevicePresentation.message(for: .io("unexpected reply"))
      }
      return response
    } catch {
      actionError = DevicePresentation.message(for: error)
      return nil
    }
  }
}
