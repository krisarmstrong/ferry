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
    await capture(
      .screenshot, named: captureName(.screenshot, of: device, at: Date()),
      in: services.captureFolders(), request: .screenshot(device))
    await refresh()
  }

  /// Creates the capture's file in the first of `folders` that takes one (where macOS saves
  /// screenshots, then the Desktop), has the agent fill it through its descriptor, then names it
  /// `base` (or the next free name) and shows it in Finder. Any failure removes the file. The
  /// file is created off the main thread: a folder macOS protects can hold the call while it asks
  /// the user. Returns whether the capture was saved.
  @discardableResult
  func capture(
    _ kind: CaptureFiles.Kind, named base: String, in folders: [URL], request: AgentRequest
  ) async -> Bool {
    let opened = await Task.detached { () -> (url: URL, handle: FileHandle)? in
      for folder in folders {
        if let file = CaptureFiles.temporary(in: folder) { return file }
      }
      return nil
    }.value
    guard let (temporary, handle) = opened else {
      actionError = DevicePresentation.message(for: .cannotSave)
      return false
    }
    let response = await sendTool(request, file: handle)
    try? handle.close()
    guard response == .done else {
      unlink(temporary.path)
      return false
    }
    do throws(TransportError) {
      let url = try CaptureFiles.place(temporary, base: base, fileExtension: kind.fileExtension)
      services.reveal([url])
      return true
    } catch {
      unlink(temporary.path)
      actionError = DevicePresentation.message(for: error)
      return false
    }
  }

  /// The name macOS would give a capture of `device` made at `date`.
  func captureName(_ kind: CaptureFiles.Kind, of device: DeviceID, at date: Date) -> String {
    let model = devices.first { $0.id == device }?.info.model ?? ""
    return CaptureFiles.baseName(kind, model: model, at: date)
  }

  /// Sends a tool request and shows a failure as the menu's error. Returns the response.
  func sendTool(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler? = nil
  ) async -> AgentResponse? {
    preservedChanges = []
    toolMessage = nil
    do {
      let response = try await client.send(request, file: file, progress: progress)
      switch response {
      case .done, .shellTarget:
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
