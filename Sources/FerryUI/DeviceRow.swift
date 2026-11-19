import DeviceKit
import FerryIPC
import SwiftUI

/// One device: a header with its model and state, how Ferry reaches it, details for that state,
/// the ADB tools when Ferry serves it over ADB (an `.apk` dropped on the row is installed), a
/// hint about USB debugging where it applies, then its actions.
struct DeviceRow: View {
  let device: AttachedDevice
  /// What the menu calls the device.
  let name: String
  let transfers: [ActiveTransfer]
  let awaitingUSBDebugging: Bool
  let eject: () -> Void
  let recheck: () -> Void
  let mount: () -> Void
  let showGuide: () -> Void
  let showUSBDebugging: () -> Void
  let network: NetworkActions
  let tools: ToolActions

  private var hint: DevicePresentation.Hint? {
    DevicePresentation.hint(for: device, awaitingUSBDebugging: awaitingUSBDebugging)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        HStack(spacing: 4) {
          Text(verbatim: name)
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
      if DevicePresentation.offersTools(device) {
        ToolRow(actions: tools)
      }
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
        NetworkButtons(actions: network)
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
    .dropDestination(for: URL.self, isEnabled: DevicePresentation.offersTools(device)) { urls, _ in
      install(urls)
    }
  }

  /// One `.apk` dropped on the row of a device with tools is installed; anything else is not.
  private func install(_ urls: [URL]) {
    guard urls.count == 1, let url = urls.first, DevicePresentation.isAPK(url) else { return }
    tools.install(url)
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
