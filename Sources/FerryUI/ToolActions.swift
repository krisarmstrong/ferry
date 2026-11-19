import DeviceKit
import FerryIPC
import SwiftUI

/// What a device row's tools show and do, and Send File….
@MainActor
struct ToolActions {
  /// The device as the menu names it, for VoiceOver.
  let name: String
  let install: AppInstall?
  let recording: ActiveRecording?
  /// The finished recording could not be saved and waits for Choose Folder… or Discard.
  let unsaved: Bool
  let chooseAPK: () -> Void
  let sendFiles: () -> Void
  let installDropped: (URL) -> Void
  let cancelInstall: () -> Void
  let screenshot: () -> Void
  let record: () -> Void
  let stopRecording: () -> Void
  let chooseFolder: () -> Void
  let discard: () -> Void
  let openLogcat: () -> Void
  let openShell: () -> Void
  let openForwards: () -> Void
  let openInfo: () -> Void

  /// `open` shows one of the developer windows for the device.
  init(model: AppModel, device: DeviceID, open: @escaping (DeveloperWindow) -> Void) {
    name = model.windowName(of: device)
    install = model.installs[device]
    recording = model.recording(on: device)
    unsaved = model.recordingUnsaved(on: device)
    chooseAPK = { Task { await model.chooseAndInstallAPK(on: device) } }
    sendFiles = { Task { await model.chooseAndSendFiles(on: device) } }
    installDropped = { url in Task { await model.installAPK(url, on: device) } }
    cancelInstall = { model.cancelInstall(on: device) }
    screenshot = { Task { await model.takeScreenshot(on: device) } }
    record = { Task { await model.startRecording(on: device) } }
    stopRecording = { Task { await model.stopRecording(on: device) } }
    chooseFolder = { Task { await model.chooseRecordingDestination(on: device) } }
    discard = { Task { await model.discardRecording(on: device) } }
    openLogcat = { open(.logcat) }
    openShell = { Task { await model.openShell(on: device) } }
    openForwards = { open(.portForwarding) }
    openInfo = { open(.deviceInfo) }
  }

  func install(_ url: URL) { installDropped(url) }
}
