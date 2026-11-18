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
        Label {
          Text("Ferry's helper is not responding. Quit Ferry and open it again.", bundle: .module)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.yellow)
        }
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
          eject: { Task { await model.eject(device.id) } },
          recheck: { Task { await model.recheck(device.id) } },
          mount: { Task { await model.mount(device.id) } },
          showGuide: { openGuide(for: device) })
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

/// One device: a header with its model and state, details for that state, then its actions.
/// Per-device tools and a connection-method label can join the header and the action row.
private struct DeviceRow: View {
  let device: AttachedDevice
  let transfers: [ActiveTransfer]
  let eject: () -> Void
  let recheck: () -> Void
  let mount: () -> Void
  let showGuide: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        HStack(spacing: 4) {
          Text(verbatim: device.displayName)
            .font(.headline)
          Text(verbatim: "·")
            .foregroundStyle(.secondary)
          Text(DevicePresentation.status(of: device.state))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
      } icon: {
        Image(systemName: symbol)
      }
      details
        .font(.callout)
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
      Text("Choose Transfer files on the device.", bundle: .module)
        .foregroundStyle(.secondary)
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
      Button(action: showGuide) {
        Text("How to turn on file transfer", bundle: .module)
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
