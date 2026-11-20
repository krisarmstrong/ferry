import DeviceKit
import FerryIPC
import SwiftUI

/// What a device row's tools show and do, its inline details, and Send File….
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
  /// The forwards while Port Forwarding is open; `nil` while it is closed.
  let forwards: PortForwardsSession?
  let toggleForwards: () -> Void
  /// The device's details as the menu shows them, and what the line just copied from shows.
  let details: DetailsShown
  let copied: (DevicePresentation.DetailLine) -> CopiedWord?
  /// A click on a detail line, with the modifier keys held as it landed.
  let click: (DevicePresentation.DetailLine, NSEvent.ModifierFlags) -> Void
  /// VoiceOver's named actions on a detail line.
  let copyAddress: (DevicePresentation.DetailLine) -> Void
  let copyAllDetails: (DevicePresentation.DetailLine) -> Void

  /// `openLogcat` shows the device's Logcat window.
  init(model: AppModel, device: DeviceID, openLogcat: @escaping () -> Void) {
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
    self.openLogcat = openLogcat
    openShell = { Task { await model.openShell(on: device) } }
    forwards = model.openForwards(of: device)
    toggleForwards = { Task { await model.toggleForwards(of: device) } }
    details = model.shownDetails(of: device)
    copied = { model.copied($0, on: device) }
    click = { line, modifiers in
      Task { await model.click(line, modifiers: modifiers, on: device) }
    }
    copyAddress = { line in Task { await model.copyAddress(line, on: device) } }
    copyAllDetails = { line in Task { await model.copyAllDetails(from: line, on: device) } }
  }

  func install(_ url: URL) { installDropped(url) }
}
