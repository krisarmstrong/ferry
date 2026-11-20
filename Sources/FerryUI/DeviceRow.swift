import DeviceKit
import FerryIPC
import FerryText
import SwiftUI

/// What a device row does, apart from its tools.
struct DeviceRowActions {
  let toggle: () -> Void
  let eject: () -> Void
  let recheck: () -> Void
  let mount: () -> Void
  let showGuide: () -> Void
  let showUSBDebugging: () -> Void
  let useOverWiFi: () -> Void
  let forget: () -> Void
}

/// One device: its tile, name and summary, and, when expanded, details for its state, what it
/// says about itself, then its actions as rows in groups divided by thin lines. An `.apk`
/// dropped on a device with tools is installed.
struct DeviceRow: View {
  let device: AttachedDevice
  /// What the menu calls the device.
  let name: String
  let summary: String
  let isExpanded: Bool
  let isRemembered: Bool
  let transfers: [ActiveTransfer]
  let awaitingUSBDebugging: Bool
  let actions: DeviceRowActions
  let tools: ToolActions

  private var recording: DevicePresentation.RecordingPhase {
    DevicePresentation.recordingPhase(tools.recording, unsaved: tools.unsaved)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExpandingRowHeader(
        tile: DevicePresentation.tile(of: device), name: name, summary: summary,
        isExpanded: isExpanded, toggle: actions.toggle)
      if isExpanded {
        if DevicePresentation.offersTools(device) {
          DetailLines(tools: tools)
        }
        DeviceDetails(
          device: device, transfers: transfers, awaitingUSBDebugging: awaitingUSBDebugging,
          tools: tools, recording: recording, showUSBDebugging: actions.showUSBDebugging)
        let groups = DevicePresentation.actionGroups(
          for: device, isRemembered: isRemembered, recording: recording)
        ForEach(groups.indices, id: \.self) { index in
          if index > 0 {
            MenuSeparator(indent: MenuMetrics.actionIndent)
          }
          ForEach(groups[index], id: \.self) { action in
            row(for: action)
          }
        }
      }
    }
    .dropDestination(for: URL.self, isEnabled: DevicePresentation.offersTools(device)) { urls, _ in
      install(urls)
    }
  }

  @ViewBuilder private func row(for action: DevicePresentation.MenuAction) -> some View {
    if action == .portForwarding {
      PortForwardRows(tools: tools)
    } else {
      MenuRow(
        title: Text(action.title), symbol: action.symbol, indent: MenuMetrics.actionIndent,
        action: perform(action)
      )
      .deviceAction(action.title, on: name)
      // One app at a time: Install App… waits for the one on its way.
      .disabled(action == .installApp && tools.install != nil)
    }
  }

  private func perform(_ action: DevicePresentation.MenuAction) -> () -> Void {
    switch action {
    case .takeScreenshot: tools.screenshot
    case .recordScreen: tools.record
    case .stopRecording: tools.stopRecording
    case .logcat: tools.openLogcat
    case .portForwarding: tools.toggleForwards
    case .sendFile: tools.sendFiles
    case .installApp: tools.chooseAPK
    case .openInTerminal: tools.openShell
    case .useOverWiFi: actions.useOverWiFi
    case .forget: actions.forget
    case .howToTurnOnFileTransfer: actions.showGuide
    case .mount: actions.mount
    case .checkAgain: actions.recheck
    case .eject: actions.eject
    // Rows of remembered devices and offers, never a device's.
    case .connectAgain, .useIt, .ignore: {}
    }
  }

  /// One `.apk` dropped on the row of a device with tools is installed; anything else is not.
  private func install(_ urls: [URL]) {
    guard urls.count == 1, let url = urls.first, PresentationText.isAPK(url) else { return }
    tools.install(url)
  }
}

/// The lines an expanded device shows above its actions: its storages and transfers,
/// what its state means, an app on its way, the recording, and USB debugging.
private struct DeviceDetails: View {
  let device: AttachedDevice
  let transfers: [ActiveTransfer]
  let awaitingUSBDebugging: Bool
  let tools: ToolActions
  let recording: DevicePresentation.RecordingPhase
  let showUSBDebugging: () -> Void

  private var hint: DevicePresentation.Hint? {
    DevicePresentation.hint(for: device, awaitingUSBDebugging: awaitingUSBDebugging)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      stateLines
      if let install = tools.install {
        Text(verbatim: DevicePresentation.installingLine(install))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      recordingLine
      if hint == .allowUSBDebugging {
        HelpLinked(key: MenuStatusText.allowUSBDebugging.key) {
          Text(MenuStatusText.allowUSBDebugging)
        }
      }
    }
    .font(.callout)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, MenuMetrics.rowPadding + MenuMetrics.actionIndent)
    .padding(.trailing, MenuMetrics.rowPadding)
    .padding(.bottom, 2)
    // Once the app is on the device, pm is installing it, which cannot be stopped.
    if let install = tools.install, DevicePresentation.offersCancel(install) {
      MenuRow(
        title: Text("Cancel", bundle: .module), symbol: "xmark.circle",
        indent: MenuMetrics.actionIndent, action: tools.cancelInstall
      )
      .deviceAction(LocalizedStringResource("Cancel", bundle: .module), on: tools.name)
    }
    if recording == .unsaved {
      MenuRow(
        title: Text("Choose Folder…", bundle: .module), symbol: "folder",
        indent: MenuMetrics.actionIndent, action: tools.chooseFolder
      )
      .deviceAction(LocalizedStringResource("Choose Folder…", bundle: .module), on: tools.name)
      MenuRow(
        title: Text("Discard", bundle: .module), symbol: "trash",
        indent: MenuMetrics.actionIndent, action: tools.discard
      )
      .deviceAction(LocalizedStringResource("Discard", bundle: .module), on: tools.name)
    }
    if hint == .moreTools {
      MenuRow(
        title: Text("More Tools with USB Debugging…", bundle: .module),
        symbol: "wrench.and.screwdriver", indent: MenuMetrics.actionIndent,
        action: showUSBDebugging
      )
      .deviceAction(
        LocalizedStringResource("More Tools with USB Debugging…", bundle: .module), on: tools.name)
    }
  }

  @ViewBuilder private var stateLines: some View {
    switch device.state {
    case .ready:
      ForEach(DevicePresentation.listedStorages(of: device), id: \.id) { storage in
        Text(verbatim: DevicePresentation.storageLine(storage))
          .foregroundStyle(.secondary)
      }
      ForEach(transfers.indices, id: \.self) { index in
        Text(verbatim: DevicePresentation.transferLine(transfers[index]))
          .lineLimit(1)
          .truncationMode(.middle)
      }
    case .notSharingFiles:
      if DevicePresentation.needsFileTransferSteps(device) {
        HelpLinked(key: MenuStatusText.chooseTransferFiles.key) {
          Text(MenuStatusText.chooseTransferFiles)
            .foregroundStyle(.secondary)
        }
      }
    case .ejected:
      Text("Not in Finder until you mount it again or plug it back in.", bundle: .module)
        .foregroundStyle(.secondary)
    case .busy:
      HelpLinked(key: MenuStatusText.busy.key) {
        Text(MenuStatusText.busy)
          .foregroundStyle(.secondary)
      }
    case .failed(let error):
      let notice = DevicePresentation.notice(for: error)
      HelpLinked(key: notice.help) {
        Text(verbatim: notice.text)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var recordingLine: some View {
    if let started = tools.recording?.started {
      Label {
        switch recording {
        case .unsaved:
          HelpLinked(key: MenuStatusText.recordingUnsaved.key) {
            Text(MenuStatusText.recordingUnsaved)
          }
        case .saving:
          Text("Saving recording…", bundle: .module)
        case .running, .none:
          HStack(spacing: 4) {
            Text("Recording", bundle: .module)
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
              .monospacedDigit()
          }
        }
      } icon: {
        Image(systemName: recording == .unsaved ? "exclamationmark.triangle" : "record.circle")
          .foregroundStyle(recording == .unsaved ? .yellow : .red)
      }
    }
  }
}
