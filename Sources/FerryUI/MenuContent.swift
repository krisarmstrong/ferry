import AppKit
import DeviceKit
import FerryIPC
import SwiftUI

/// The menu-bar window, after Control Center's Wi-Fi and Bluetooth menus: a header with
/// Refresh, anything that needs the user's attention, the devices (one expanded at a time, with
/// its actions as rows), the network forms (opening in place), then Open at Login, Help and
/// Quit.
///
/// While it is open it refreshes every 2 s (see `AppModel.watchWhileMenuOpen()`), and it opens
/// the setup guide when the model asks for it.
public struct MenuContent: View {
  @Environment(\.openWindow) private var openWindow
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      statusRows
      devices
      MenuSeparator()
      if model.agent == .running, model.adbStatus != nil {
        NetworkFormRows(model: model)
        MenuSeparator()
      }
      MenuFooter(model: model)
    }
    .padding(6)
    .frame(width: 320, alignment: .leading)
    // For the Help links beside its problems (see `HelpLinkButton`).
    .environment(model)
    .task { await model.watchWhileMenuOpen() }
    .onChange(of: model.guideOpenPending, initial: true) { _, _ in
      if model.takeGuideOpenRequest() {
        NSApp.activate()
        openWindow(id: SetupGuide.windowID)
      }
    }
  }

  private var header: some View {
    HStack {
      Text("Ferry", bundle: .module)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Button {
        Task { await model.refreshDevices() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("r")
      .help(Text("Refresh", bundle: .module))
      .accessibilityLabel(Text("Refresh", bundle: .module))
    }
    .padding(.leading, MenuMetrics.rowPadding)
    .padding(.trailing, 4)
    .padding(.vertical, 4)
  }

  /// What needs the user's attention, each a compact row with a leading symbol.
  @ViewBuilder private var statusRows: some View {
    if model.isChecking {
      StatusRow(symbol: "ellipsis.circle", title: Text("Checking…", bundle: .module))
    }
    if model.agent == .unreachable {
      HelperRow(status: model.helper) { model.openLoginItems() }
    }
    if model.agent == .replaced {
      StatusRow(
        symbol: "arrow.clockwise.circle", tint: .yellow, title: Text(MenuStatusText.updated),
        help: MenuStatusText.updated.key
      ) {
        StatusAction(title: Text("Relaunch", bundle: .module)) { model.relaunch() }
      }
    }
    if model.showsTurnOnRow {
      StatusRow(
        symbol: "questionmark.circle", title: Text(MenuStatusText.turnOnInFinder),
        help: MenuStatusText.turnOnInFinder.key
      ) {
        Text("In Login Items & Extensions, turn on Ferry under File Providers.", bundle: .module)
      } actions: {
        StatusAction(title: Text("Open System Settings", bundle: .module)) {
          model.turnOnInFinder()
        }
      }
    }
    if model.showsNoDevice {
      StatusRow(
        symbol: "cable.connector", title: Text(MenuStatusText.noDevice),
        help: MenuStatusText.noDevice.key
      ) {
        Text("Choose Transfer files on the device.", bundle: .module)
      } actions: {
        StatusAction(title: Text("How to Connect", bundle: .module)) { openGuide(for: nil) }
      }
    }
    if model.showsADBNotRunning {
      ADBNotRunningRow { Task { await model.recheckADB() } }
    }
    if model.showsInstallADB {
      InstallADBRow(
        copy: { model.copyInstallCommand() }, checkAgain: { Task { await model.recheckADB() } })
    }
    ForEach(model.awaitingAuthorization, id: \.self) { address in
      let line = DevicePresentation.waitingLine(for: address)
      StatusRow(symbol: "hand.raised", title: Text(verbatim: line.text), help: line.help)
    }
    if let message = model.wirelessMessage {
      StatusRow(
        symbol: "wifi.exclamationmark", title: Text(verbatim: message.text), help: message.help)
    }
    if let message = model.toolMessage {
      StatusRow(symbol: "info.circle", title: Text(verbatim: message))
    }
    // Once the agent refuses this copy every action fails the same way: the row says why.
    if let error = model.actionError, model.agent != .replaced {
      StatusRow(
        symbol: "exclamationmark.triangle", tint: .red, title: Text(verbatim: error.text),
        help: error.help)
    }
    if !model.preservedChanges.isEmpty {
      PreservedChangesRow(locations: model.preservedChanges) {
        model.revealPreservedChanges()
      }
    }
    if model.agent == .running, model.usbWatchFailed {
      StatusRow(
        symbol: "info.circle", title: Text(MenuStatusText.usbWatchFailed),
        help: MenuStatusText.usbWatchFailed.key)
    }
  }

  /// The devices, then remembered devices not nearby, then addresses offered for known devices.
  @ViewBuilder private var devices: some View {
    if !model.devices.isEmpty || !model.rememberedOffline.isEmpty || !model.unconfirmed.isEmpty {
      Text("Devices", bundle: .module)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, MenuMetrics.rowPadding)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
    ForEach(model.devices) { device in
      deviceRow(device)
    }
    ForEach(model.rememberedOffline) { device in
      RememberedRow(
        device: device, isExpanded: model.isExpanded(.remembered(device.id)),
        toggle: { model.toggleExpansion(.remembered(device.id)) },
        connect: { Task { await model.connectAgain(device.id) } },
        forget: { Task { await model.forget(device.id) } })
    }
    ForEach(model.unconfirmed, id: \.self) { offer in
      UnconfirmedRow(
        offer: offer, isExpanded: model.isExpanded(.offer(offer.address)),
        toggle: { model.toggleExpansion(.offer(offer.address)) },
        confirm: { Task { await model.confirm(offer) } },
        ignore: { Task { await model.ignore(offer.address) } })
    }
  }

  private func deviceRow(_ device: AttachedDevice) -> some View {
    DeviceRow(
      device: device, name: model.displayName(of: device),
      summary: DevicePresentation.summary(
        of: device, address: model.wirelessAddress(of: device.id)),
      isExpanded: model.isExpanded(.device(device.id)),
      isRemembered: model.isRemembered(device.id),
      transfers: model.transfers(on: device.id),
      awaitingUSBDebugging: model.isAwaitingUSBDebugging(device.id),
      actions: DeviceRowActions(
        toggle: { model.toggleExpansion(.device(device.id)) },
        eject: { Task { await model.eject(device.id) } },
        recheck: { Task { await model.recheck(device.id) } },
        mount: { Task { await model.mount(device.id) } },
        showGuide: { openGuide(for: device) },
        showUSBDebugging: { openUSBDebuggingGuide(for: device) },
        useOverWiFi: { Task { await model.useOverWiFi(device.id) } },
        forget: { Task { await model.forget(device.id) } }),
      tools: ToolActions(
        model: model, device: device.id,
        openLogcat: {
          NSApp.activate()
          openWindow(id: LogcatWindow.windowID, value: device.id)
        }))
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
    switch status {
    case .allowed:
      StatusRow(
        symbol: "exclamationmark.triangle", tint: .yellow,
        title: Text(MenuStatusText.helperNotResponding),
        help: MenuStatusText.helperNotResponding.key)
    case .requiresApproval:
      blocked(MenuStatusText.allowHelper)
    case .notFound:
      blocked(MenuStatusText.helperNotFound)
    }
  }

  private func blocked(_ title: LocalizedStringResource) -> some View {
    StatusRow(
      symbol: "exclamationmark.triangle", tint: .yellow, title: Text(title), help: title.key
    ) {
      Text(
        "In Login Items & Extensions, turn on Ferry under Allow in the Background.",
        bundle: .module)
    } actions: {
      StatusAction(title: Text("Open System Settings", bundle: .module), action: openSettings)
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
