import DeviceKit
import FerryIPC
import FerrySyncCore
import FerryText
import Foundation

/// An app the menu is installing.
public struct AppInstall: Sendable, Equatable {
  /// The file's name, as the user picked it.
  public let name: String
  /// Whole percent of the file on the device; installing follows at 100.
  public var percent: Int
}

/// The ADB tools: Install App…, a screenshot and a screen recording, for a device Ferry serves
/// over ADB. The app creates each screenshot and recording file in the device's folder (see
/// `CaptureFiles`), the agent fills it through its descriptor, and the app names it and shows it
/// in Finder.
extension AppModel {
  /// Install App…: asks for an `.apk`, then installs it.
  public func chooseAndInstallAPK(on device: DeviceID) async {
    guard let url = await services.chooseAPK() else { return }
    await installAPK(url, on: device)
  }

  /// Installs the `.apk` at `url`, sent to the agent as an open file. Anything else (a file
  /// dropped on the row) is not sent; the agent checks the contents again.
  public func installAPK(_ url: URL, on device: DeviceID) async {
    guard PresentationText.isAPK(url), installs[device] == nil else { return }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      // The file on the Mac, not the device: the menu must not suggest reconnecting it.
      Self.log.error("reading the app to install failed: \(error, privacy: .private)")
      actionError = MenuNotice(
        text: String(localized: FinderSender.unreadableResource),
        help: FinderSender.unreadableResource.key)
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
    let sending = Task {
      await sendTool(.installAPK(device, name: name), file: handle, progress: progress)
    }
    installRequests[device] = sending
    let response = await sending.value
    installRequests[device] = nil
    installs[device] = nil
    if response == .done { toolMessage = DevicePresentation.installedLine(name) }
    await refresh()
  }

  /// Cancel: stops the copy to the device; the agent removes what reached it. The user asked,
  /// so it is not shown as an error.
  public func cancelInstall(on device: DeviceID) {
    installRequests[device]?.cancel()
  }

  public func takeScreenshot(on device: DeviceID) async {
    await capture(
      .screenshot, named: captureName(.screenshot, of: device, at: Date()),
      in: captureFolders(CaptureFiles.screenshotsFolder, of: device), request: .screenshot(device))
    await refresh()
  }

  /// How a capture ended.
  enum CaptureResult: Equatable {
    case saved
    /// No folder took the file, or it could not be named there.
    case noFolder
    /// The agent did not fill the file: its answer, or `nil` if it could not be reached.
    case notSent(AgentResponse?)
  }

  /// Creates the capture's file in the first of `folders` that takes one, making the folder if
  /// it is missing, has the agent fill it through its descriptor, then names it `base` (or the
  /// next free name) and shows it in Finder. Any failure removes the file. The folder and file
  /// are made off the main thread: a folder macOS protects can hold the call while it asks the
  /// user. A capture the user did not ask for now (`userInitiated` false: a recording saved
  /// on its own) leaves what the menu shows alone; its outcome shows in its own row.
  @discardableResult
  func capture(
    _ kind: CaptureFiles.Kind, named base: String, in folders: [URL], request: AgentRequest,
    userInitiated: Bool = true
  ) async -> CaptureResult {
    let opened = await Task.detached { () -> (url: URL, handle: FileHandle)? in
      for folder in folders {
        CaptureFiles.make(folder)
        guard let file = CaptureFiles.temporary(in: folder) else { continue }
        // Ferry has access to this folder now: clear what a quit or crash mid-save left here.
        CaptureFiles.sweep([folder])
        return file
      }
      return nil
    }.value
    guard let (temporary, handle) = opened else {
      if userInitiated { actionError = DevicePresentation.notice(for: .cannotSave) }
      return .noFolder
    }
    let response = await sendTool(request, file: handle, userInitiated: userInitiated)
    try? handle.close()
    guard response == .done else {
      unlink(temporary.path)
      return .notSent(response)
    }
    do throws(TransportError) {
      let url = try CaptureFiles.place(temporary, base: base, fileExtension: kind.fileExtension)
      services.reveal([url])
      return .saved
    } catch {
      unlink(temporary.path)
      if userInitiated { actionError = DevicePresentation.notice(for: error) }
      return .noFolder
    }
  }

  /// The device's `name` folder (Screenshots, Screen Recordings) under each capture folder,
  /// named for the device as the menu names it.
  func captureFolders(_ name: String, of device: DeviceID) -> [URL] {
    let named = devices.map { ($0.id, $0.info.name) }
    let suffix = DeviceNames.suffixes(for: named)[device]
    let deviceName = DeviceNames.named(
      devices.first { $0.id == device }?.info.name ?? "", suffix: suffix)
    return services.captureFolders().map {
      CaptureFiles.folder(name, device: deviceName, in: $0)
    }
  }

  /// The name macOS would give a capture of `device` made at `date`.
  func captureName(_ kind: CaptureFiles.Kind, of device: DeviceID, at date: Date) -> String {
    let model = devices.first { $0.id == device }?.info.model ?? ""
    return CaptureFiles.baseName(kind, model: model, at: date)
  }

  /// Sends a tool request and shows a failure as the menu's error. Returns the response. One
  /// the user did not ask for now (`userInitiated` false) leaves what the menu shows alone.
  func sendTool(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler? = nil,
    userInitiated: Bool = true
  ) async -> AgentResponse? {
    guard userInitiated else {
      do {
        return try await client.send(request, file: file, progress: progress)
      } catch {
        Self.log.info("background request failed: \(String(describing: error), privacy: .private)")
        return nil
      }
    }
    keepPreservedChanges()
    toolMessage = nil
    do {
      let response = try await client.send(request, file: file, progress: progress)
      switch response {
      case .done, .shellTarget, .failure(.cancelled):
        actionError = nil
      case .toolFailed(let failure):
        actionError = DevicePresentation.notice(for: failure)
      case .failure(let error):
        actionError = DevicePresentation.notice(for: error)
      default:
        actionError = DevicePresentation.notice(for: .io("unexpected reply"))
      }
      return response
    } catch .cancelled {
      actionError = nil
      return nil
    } catch {
      actionError = DevicePresentation.notice(for: error)
      return nil
    }
  }
}

extension AppModel {
  /// Send File…: asks for files, then sends them into the device's Download folder as Finder's
  /// Send to does (see `FinderSender`), which opens each one itself, refusing links and anything
  /// but a regular file.
  public func chooseAndSendFiles(on device: DeviceID) async {
    let urls = await services.chooseFilesToSend()
    guard !urls.isEmpty else { return }
    keepPreservedChanges()
    toolMessage = nil
    let (notice, failed) = await FinderSender(agent: client).performReporting(
      .send(device), on: urls, deviceName: windowName(of: device))
    let text = [notice.title, notice.body].filter { !$0.isEmpty }.joined(separator: "\n")
    if failed {
      actionError = MenuNotice(text: text, help: notice.help)
    } else {
      actionError = nil
      toolMessage = text
    }
    await refresh()
  }
}
