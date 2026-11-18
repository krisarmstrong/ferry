import AppKit
import DeviceKit
import FerryIPC
import SwiftUI

/// The menu-bar window: each device with its state, then Refresh, Help, Settings and Quit.
///
/// While it is open it refreshes every 2 s (see `AppModel.watchWhileMenuOpen()`), and it opens
/// the setup guide when the model asks for it.
public struct MenuContent: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.isChecking {
        Label {
          Text("Checking…", bundle: .module)
        } icon: {
          ProgressView()
            .controlSize(.small)
        }
      }
      if model.agent == .unreachable {
        HelperRow(status: model.helper) { model.openLoginItems() }
      }
      if model.showsTurnOnRow {
        TurnOnRow { model.turnOnInFinder() }
      }
      if model.agent == .running, model.devices.isEmpty {
        NoDeviceRow { openGuide(for: nil) }
      }
      ForEach(model.devices) { device in
        DeviceRow(
          device: device, transfers: model.transfers(on: device.id),
          awaitingUSBDebugging: model.isAwaitingUSBDebugging(device.id),
          eject: { Task { await model.eject(device.id) } },
          recheck: { Task { await model.recheck(device.id) } },
          mount: { Task { await model.mount(device.id) } },
          showGuide: { openGuide(for: device) },
          showUSBDebugging: { openUSBDebuggingGuide(for: device) })
      }
      ForEach(model.awaitingAuthorization, id: \.self) { address in
        Text(verbatim: DevicePresentation.waitingLine(for: address))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if model.showsADBNotRunning {
        ADBNotRunningRow { Task { await model.recheckADB() } }
      }
      if model.showsInstallADB {
        InstallADBRow(
          copy: { model.copyInstallCommand() }, checkAgain: { Task { await model.recheckADB() } })
      }
      if let error = model.actionError {
        Text(verbatim: error)
          .font(.callout)
          .foregroundStyle(.red)
      }
      if !model.preservedChanges.isEmpty {
        PreservedChangesRow(locations: model.preservedChanges) {
          model.revealPreservedChanges()
        }
      }
      Divider()
      HStack {
        Button {
          Task { await model.refreshDevices() }
        } label: {
          Label {
            Text("Refresh", bundle: .module)
          } icon: {
            Image(systemName: "arrow.clockwise")
          }
        }
        .keyboardShortcut("r")
        Spacer()
        Button {
          NSApp.activate()
          openWindow(id: HelpView.windowID)
        } label: {
          Label {
            Text("Help", bundle: .module)
          } icon: {
            Image(systemName: "questionmark.circle")
          }
          .labelStyle(.iconOnly)
        }
        .help(Text("Ferry Help", bundle: .module))
        .keyboardShortcut("?")
        Button {
          NSApp.activate()
          openSettings()
        } label: {
          Text("Settings…", bundle: .module)
        }
        .keyboardShortcut(",")
        Button {
          NSApp.terminate(nil)
        } label: {
          Text("Quit", bundle: .module)
        }
        .keyboardShortcut("q")
      }
    }
    .padding(12)
    .frame(width: 320, alignment: .leading)
    .task { await model.watchWhileMenuOpen() }
    .onChange(of: model.guideOpenPending, initial: true) { _, _ in
      if model.takeGuideOpenRequest() {
        NSApp.activate()
        openWindow(id: SetupGuide.windowID)
      }
    }
  }

  private func openGuide(for device: AttachedDevice?) {
    model.showGuide(for: device)
  }

  private func openUSBDebuggingGuide(for device: AttachedDevice) {
    model.showUSBDebuggingGuide(for: device)
  }
}

/// The agent did not answer. If macOS will not run it, the fix is in System Settings.
private struct HelperRow: View {
  let status: HelperStatus
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        switch status {
        case .allowed:
          Text("Ferry's helper is not responding. Quit Ferry and open it again.", bundle: .module)
        case .requiresApproval:
          Text("Allow Ferry's helper", bundle: .module)
            .font(.headline)
        case .notFound:
          Text("macOS can't find Ferry's helper", bundle: .module)
            .font(.headline)
        }
      } icon: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.yellow)
      }
      if status != .allowed {
        Text(
          "In Login Items & Extensions, turn on Ferry under Allow in the Background.",
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button(action: openSettings) {
          Text("Open System Settings", bundle: .module)
        }
      }
    }
  }
}

/// Finder shows nothing until the user turns Ferry on in System Settings: a step, not an error.
private struct TurnOnRow: View {
  let turnOn: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("Turn on Ferry in Finder", bundle: .module)
          .font(.headline)
      } icon: {
        Image(systemName: "questionmark.circle")
      }
      Text(
        "In Login Items & Extensions, turn on Ferry under File Providers.", bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Button(action: turnOn) {
        Text("Open System Settings", bundle: .module)
      }
    }
  }
}

/// An eject removed a location that still had changes for the device; the system kept them.
private struct PreservedChangesRow: View {
  let locations: [URL]
  let reveal: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(locations, id: \.self) { location in
        Text("Unsent changes were saved to \(Self.shown(location))", bundle: .module)
          .font(.callout)
      }
      Button(action: reveal) {
        Text("Reveal in Finder", bundle: .module)
      }
    }
  }

  /// The path with the home folder as `~`. The folder can be named after a device, which
  /// chooses its own name, so it is escaped.
  private static func shown(_ location: URL) -> String {
    DisplayText.escaped((location.path as NSString).abbreviatingWithTildeInPath)
  }
}

private struct NoDeviceRow: View {
  let showGuide: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("No device connected", bundle: .module)
          .font(.headline)
      } icon: {
        Image(systemName: "cable.connector")
      }
      Text("Choose Transfer files on the device.", bundle: .module)
        .font(.callout)
        .foregroundStyle(.secondary)
      Button(action: showGuide) {
        Text("How to connect", bundle: .module)
      }
    }
  }
}

/// One device: a header with its model and state, how Ferry reaches it, details for that state,
/// a hint about USB debugging where it applies, then its actions. Per-device tools can join the
/// action row.
private struct DeviceRow: View {
  let device: AttachedDevice
  let transfers: [ActiveTransfer]
  let awaitingUSBDebugging: Bool
  let eject: () -> Void
  let recheck: () -> Void
  let mount: () -> Void
  let showGuide: () -> Void
  let showUSBDebugging: () -> Void

  private var hint: DevicePresentation.Hint? {
    DevicePresentation.hint(for: device, awaitingUSBDebugging: awaitingUSBDebugging)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        HStack(spacing: 4) {
          Text(verbatim: device.displayName)
            .font(.headline)
          Text(verbatim: "·")
            .foregroundStyle(.secondary)
          Text(DevicePresentation.status(of: device))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
      } icon: {
        Image(systemName: symbol)
      }
      if let method = DevicePresentation.shownMethod(of: device) {
        Text(DevicePresentation.method(method))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      details
        .font(.callout)
      switch hint {
      case .allowUSBDebugging:
        Text("Allow USB debugging on the device", bundle: .module)
          .font(.callout)
      case .moreTools:
        Button(action: showUSBDebugging) {
          Text("More tools with USB debugging…", bundle: .module)
        }
      case nil:
        EmptyView()
      }
      HStack {
        stateAction
        Spacer()
        // Only a device Ferry holds open can be ejected.
        if case .ready = device.state {
          Button(action: eject) {
            Label {
              Text("Eject", bundle: .module)
            } icon: {
              Image(systemName: "eject")
            }
          }
        }
      }
    }
  }

  private var symbol: String {
    switch device.state {
    case .ready: "externaldrive.connected.to.line.below"
    case .notSharingFiles: "cable.connector"
    case .ejected: "eject"
    case .busy, .failed: "exclamationmark.triangle"
    }
  }

  @ViewBuilder private var details: some View {
    switch device.state {
    case .ready(let storages):
      ForEach(storages, id: \.id) { storage in
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
        Text("Choose Transfer files on the device.", bundle: .module)
          .foregroundStyle(.secondary)
      }
    case .ejected:
      Text("Not in Finder until you mount it again or plug it back in.", bundle: .module)
        .foregroundStyle(.secondary)
    case .busy:
      Text("Quit Image Capture or Android File Transfer, then try again.", bundle: .module)
        .foregroundStyle(.secondary)
    case .failed(let error):
      Text(verbatim: DevicePresentation.message(for: error))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var stateAction: some View {
    switch device.state {
    case .ready:
      EmptyView()
    case .notSharingFiles:
      if DevicePresentation.needsFileTransferSteps(device) {
        Button(action: showGuide) {
          Text("How to turn on file transfer", bundle: .module)
        }
      }
    case .ejected:
      Button(action: mount) {
        Text("Mount", bundle: .module)
      }
    case .busy, .failed:
      Button(action: recheck) {
        Text("Try Again", bundle: .module)
      }
    }
  }
}

#Preview("Ready") {
  MenuContent(model: .preview([PreviewClient.ready]))
}

#Preview("Methods") {
  MenuContent(
    model: .preview(
      [
        PreviewClient.ready, PreviewClient.readyOverADB, PreviewClient.readyOverWiFi,
      ], adb: .notInstalled))
}

#Preview("Not sharing, busy, failed") {
  MenuContent(
    model: .preview([PreviewClient.notSharing, PreviewClient.busy, PreviewClient.failed]))
}

#Preview("No device") {
  MenuContent(model: .preview([]))
}

#Preview("Turn on in Finder") {
  MenuContent(model: .preview([PreviewClient.ready], provider: .disabled))
}
