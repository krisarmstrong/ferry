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
/// over ADB. The app creates each screenshot and recording file where macOS saves its own, the
/// agent fills it through its descriptor, and the app names it and shows it in Finder.
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
    await capture(.screenshot, of: device, at: Date(), request: .screenshot(device))
    await refresh()
  }

  /// Starts a recording. The agent answers once it has ended (Stop, or its time limit), and the
  /// video is collected then; meanwhile the status shows it running.
  public func startRecording(on device: DeviceID) async {
    guard recording(on: device) == nil else { return }
    requestedRecordings[device] = Date()
    let response = await sendTool(.startRecording(device), file: nil)
    requestedRecordings[device] = nil
    await refresh()
    if response == .done { await collectRecording(on: device) }
  }

  public func stopRecording(on device: DeviceID) async {
    _ = await sendTool(.stopRecording(device), file: nil)
    await refresh()
  }

  /// Collects each finished recording the status lists that is not being collected already.
  func collectFinishedRecordings() {
    for recording in recordings
    where recording.finished && !collectingRecordings.contains(recording.device) {
      Task { await collectRecording(on: recording.device) }
    }
  }

  /// Saves a finished recording and shows it. A recording that finished while no request
  /// waited for it (the app was relaunched) is collected when the status lists it.
  func collectRecording(on device: DeviceID) async {
    guard let recording = recordings.first(where: { $0.device == device && $0.finished }),
      collectingRecordings.insert(device).inserted
    else { return }
    defer { collectingRecordings.remove(device) }
    await capture(.recording, of: device, at: recording.started, request: .saveRecording(device))
    await refresh()
  }

  /// Creates the capture's file where macOS saves screenshots (else the Desktop), has the agent
  /// fill it through its descriptor, then names it and shows it in Finder. Any failure removes
  /// the file.
  private func capture(
    _ kind: CaptureFiles.Kind, of device: DeviceID, at date: Date, request: AgentRequest
  ) async {
    var opened: (url: URL, handle: FileHandle)?
    for folder in services.captureFolders() where opened == nil {
      opened = CaptureFiles.temporary(in: folder)
    }
    guard let (temporary, handle) = opened else {
      actionError = DevicePresentation.message(for: .cannotSave)
      return
    }
    let response = await sendTool(request, file: handle)
    try? handle.close()
    guard response == .done else {
      unlink(temporary.path)
      return
    }
    let model = devices.first { $0.id == device }?.info.model ?? ""
    do throws(TransportError) {
      let url = try CaptureFiles.place(
        temporary, base: CaptureFiles.baseName(kind, model: model, at: date),
        fileExtension: kind.fileExtension)
      services.reveal([url])
    } catch {
      unlink(temporary.path)
      actionError = DevicePresentation.message(for: error)
    }
  }

  /// Sends a tool request and shows a failure as the menu's error. Returns the response.
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
