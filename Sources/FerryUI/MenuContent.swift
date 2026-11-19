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
      if model.agent == .replaced {
        ReplacedRow { model.relaunch() }
      }
      if model.showsTurnOnRow {
        TurnOnRow { model.turnOnInFinder() }
      }
      if model.showsNoDevice {
        NoDeviceRow { openGuide(for: nil) }
      }
      ForEach(model.devices) { device in
        DeviceRow(
          device: device, name: model.displayName(of: device),
          transfers: model.transfers(on: device.id),
          awaitingUSBDebugging: model.isAwaitingUSBDebugging(device.id),
          eject: { Task { await model.eject(device.id) } },
          recheck: { Task { await model.recheck(device.id) } },
          mount: { Task { await model.mount(device.id) } },
          showGuide: { openGuide(for: device) },
          showUSBDebugging: { openUSBDebuggingGuide(for: device) },
          network: NetworkActions(
            name: model.displayName(of: device), offersWiFi: DevicePresentation.offersWiFi(device),
            isRemembered: model.isRemembered(device.id),
            useOverWiFi: { Task { await model.useOverWiFi(device.id) } },
            forget: { Task { await model.forget(device.id) } }),
          tools: ToolActions(
            model: model, device: device.id,
            open: { window in
              NSApp.activate()
              openWindow(id: window.windowID, value: device.id)
            }))
      }
      ForEach(model.rememberedOffline) { device in
        RememberedRow(
          device: device, connect: { Task { await model.connectAgain(device.id) } },
          forget: { Task { await model.forget(device.id) } })
      }
      ForEach(model.unconfirmed, id: \.self) { offer in
        UnconfirmedRow(
          offer: offer, confirm: { Task { await model.confirm(offer) } },
          ignore: { Task { await model.ignore(offer.address) } })
      }
      ForEach(model.awaitingAuthorization, id: \.self) { address in
        Text(verbatim: DevicePresentation.waitingLine(for: address))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      NetworkRow(
        message: model.wirelessMessage,
        offersForms: model.agent == .running && model.adbStatus != nil,
        open: openNetworkForm)
      if model.agent == .running, model.usbWatchFailed {
        Text(
          "Ferry can't watch USB for devices, so it looks for them every 30 seconds.",
          bundle: .module
        )
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
      if let message = model.toolMessage {
        Text(verbatim: message)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      // Once the agent refuses this copy every action fails the same way: the row says why.
      if let error = model.actionError, model.agent != .replaced {
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

  private func openNetworkForm(_ form: WirelessForm) {
    model.openNetworkForm(form)
    NSApp.activate()
    openWindow(id: PairDeviceView.windowID)
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

/// Ferry was updated while it ran, and the new agent refuses this copy: reopening runs the new
/// one.
private struct ReplacedRow: View {
  let relaunch: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("Ferry was updated. Quit and reopen Ferry.", bundle: .module)
      } icon: {
        Image(systemName: "arrow.clockwise.circle")
          .foregroundStyle(.yellow)
      }
      Button(action: relaunch) {
        Text("Relaunch", bundle: .module)
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
        Text("How to Connect", bundle: .module)
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
