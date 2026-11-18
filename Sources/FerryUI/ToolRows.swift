import DeviceKit
import FerryIPC
import SwiftUI

/// What a device row's tools show and do.
@MainActor
struct ToolActions {
  let install: AppInstall?
  let recording: ActiveRecording?
  let chooseAPK: () -> Void
  let installDropped: (URL) -> Void
  let screenshot: () -> Void
  let record: () -> Void
  let stopRecording: () -> Void

  init(model: AppModel, device: DeviceID) {
    install = model.installs[device]
    recording = model.recording(on: device)
    chooseAPK = { Task { await model.chooseAndInstallAPK(on: device) } }
    installDropped = { url in Task { await model.installAPK(url, on: device) } }
    screenshot = { Task { await model.takeScreenshot(on: device) } }
    record = { Task { await model.startRecording(on: device) } }
    stopRecording = { Task { await model.stopRecording(on: device) } }
  }

  func install(_ url: URL) { installDropped(url) }
}

/// Install App…, Screenshot and Record Screen, an app's progress on its way to the device, and
/// the recording indicator with its elapsed time and Stop.
struct ToolRow: View {
  let actions: ToolActions

  var body: some View {
    if let install = actions.install {
      Text(verbatim: DevicePresentation.installingLine(install))
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    if let recording = actions.recording {
      HStack {
        Label {
          if recording.stopping {
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
        if !recording.stopping {
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
  }
}
