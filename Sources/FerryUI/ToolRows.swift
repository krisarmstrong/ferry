import DeviceKit
import FerryIPC
import SwiftUI

/// What a device row's tools show and do.
@MainActor
struct ToolActions {
  let install: AppInstall?
  let recording: ActiveRecording?
  /// The finished recording could not be saved and waits for Choose Folder… or Discard.
  let unsaved: Bool
  let chooseAPK: () -> Void
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
    install = model.installs[device]
    recording = model.recording(on: device)
    unsaved = model.recordingUnsaved(on: device)
    chooseAPK = { Task { await model.chooseAndInstallAPK(on: device) } }
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

/// Install App…, Screenshot and Record Screen, an app's progress on its way to the device, and
/// the recording indicator with its elapsed time and Stop.
struct ToolRow: View {
  let actions: ToolActions

  var body: some View {
    if let install = actions.install {
      HStack {
        Text(verbatim: DevicePresentation.installingLine(install))
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
        // Once the app is on the device, pm is installing it, which cannot be stopped.
        if DevicePresentation.offersCancel(install) {
          Button(action: actions.cancelInstall) {
            Text("Cancel", bundle: .module)
          }
        }
      }
    }
    if let recording = actions.recording, recording.finished, actions.unsaved {
      VStack(alignment: .leading, spacing: 6) {
        Label {
          Text("Recording couldn't be saved", bundle: .module)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.yellow)
        }
        .font(.callout)
        HStack {
          Button(action: actions.chooseFolder) {
            Text("Choose Folder…", bundle: .module)
          }
          Button(action: actions.discard) {
            Text("Discard", bundle: .module)
          }
        }
      }
    } else if let recording = actions.recording {
      HStack {
        Label {
          if recording.stopping || recording.finished {
            Text("Saving recording…", bundle: .module)
          } else {
            HStack(spacing: 4) {
              Text("Recording", bundle: .module)
              Text(timerInterval: recording.started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
            }
          }
        } icon: {
          Image(systemName: "record.circle")
            .foregroundStyle(.red)
        }
        .font(.callout)
        Spacer()
        if !recording.stopping && !recording.finished {
          Button(action: actions.stopRecording) {
            Text("Stop", bundle: .module)
          }
        }
      }
    }
    HStack {
      Button(action: actions.chooseAPK) {
        Text("Install App…", bundle: .module)
      }
      .disabled(actions.install != nil)
      Button(action: actions.screenshot) {
        Text("Screenshot", bundle: .module)
      }
      if actions.recording == nil {
        Button(action: actions.record) {
          Text("Record Screen", bundle: .module)
        }
      }
    }
    .controlSize(.small)
    Menu {
      Button(action: actions.openLogcat) {
        Text("Logcat…", bundle: .module)
      }
      Button(action: actions.openShell) {
        Text("Open Shell", bundle: .module)
      }
      Button(action: actions.openForwards) {
        Text("Port Forwarding…", bundle: .module)
      }
      Button(action: actions.openInfo) {
        Text("Device Info…", bundle: .module)
      }
    } label: {
      Text("Developer Tools", bundle: .module)
    }
    .controlSize(.small)
    .fixedSize()
  }
}
