import DeviceKit
import FerryIPC
import FerryText
import Foundation

/// What each row of the menu shows and offers: a round tile, a one-line summary under the name,
/// and the actions its expansion lists.
extension DevicePresentation {
  /// The round tile at the start of a row: filled with the accent colour while Ferry serves the
  /// device, neutral otherwise.
  struct Tile: Equatable {
    let symbol: String
    let isActive: Bool
  }

  static func tile(of device: AttachedDevice) -> Tile {
    let symbol = device.method == .wifiADB ? "wifi" : "cable.connector"
    if case .ready = device.state { return Tile(symbol: symbol, isActive: true) }
    return Tile(symbol: symbol, isActive: false)
  }

  static let rememberedTile = Tile(symbol: "wifi.slash", isActive: false)
  static let offerTile = Tile(symbol: "wifi", isActive: false)

  /// The line under a device's name. A ready device shows how Ferry reaches it, then its network
  /// address over Wi-Fi when Ferry has one, or else the first storage's free space; any other
  /// device shows its state.
  static func summary(of device: AttachedDevice, address: WirelessEndpoint?) -> String {
    guard case .ready(let storages) = device.state else {
      return String(localized: status(of: device))
    }
    let link =
      device.method == .wifiADB
      ? String(localized: LocalizedStringResource("Wi-Fi", bundle: .module))
      : String(localized: LocalizedStringResource("USB", bundle: .module))
    let detail: String
    if device.method == .wifiADB, let address {
      detail = shown(address)
    } else if let storage = storages.first {
      let free = storage.free.formatted(.byteCount(style: .file))
      return String(localized: LocalizedStringResource("\(link) · \(free) free", bundle: .module))
    } else {
      detail = String(localized: status(of: device.state))
    }
    return String(localized: LocalizedStringResource("\(link) · \(detail)", bundle: .module))
  }

  /// The address as the user typed it: adb's usual port goes unsaid. adb reported it, so it is
  /// escaped.
  private static func shown(_ address: WirelessEndpoint) -> String {
    DisplayText.escaped(
      address.port == WirelessEndpoint.defaultPort ? address.host : address.argument)
  }

  /// The storages an expanded device lists. The summary already gives the first one's free
  /// space, so a single storage is not listed again.
  static func listedStorages(of device: AttachedDevice) -> [StorageInfo] {
    guard case .ready(let storages) = device.state, storages.count > 1 else { return [] }
    return storages
  }

  static var rememberedSummary: String {
    String(localized: LocalizedStringResource("Remembered · not nearby", bundle: .module))
  }

  static func offerSummary(_ offer: UnconfirmedAddress) -> String {
    shown(offer.address)
  }

  /// What VoiceOver reads for a device row: the name, then the summary.
  static func rowLabel(name: String, summary: String) -> String {
    String(localized: LocalizedStringResource("\(name), \(summary)", bundle: .module))
  }

  /// Where a screen recording has got, which decides the recording row.
  enum RecordingPhase: Sendable {
    case none
    case running
    /// Stopping, or finished and being saved.
    case saving
    /// Finished, and waiting for Choose Folder… or Discard.
    case unsaved
  }

  /// A row in a device's expansion.
  enum MenuAction: Hashable, CaseIterable, Sendable {
    case takeScreenshot, recordScreen, stopRecording, logcat, deviceInfo, portForwarding
    case sendFile, installApp, openShell, useOverWiFi, forget, howToTurnOnFileTransfer, mount
    case checkAgain, eject, connectAgain, useIt, ignore

    var title: LocalizedStringResource {
      switch self {
      case .takeScreenshot: LocalizedStringResource("Take Screenshot", bundle: .module)
      case .recordScreen: LocalizedStringResource("Record Screen", bundle: .module)
      case .stopRecording: LocalizedStringResource("Stop Recording", bundle: .module)
      case .logcat: LocalizedStringResource("Logcat", bundle: .module)
      case .deviceInfo: LocalizedStringResource("Device Info", bundle: .module)
      case .portForwarding: LocalizedStringResource("Port Forwarding", bundle: .module)
      case .sendFile: LocalizedStringResource("Send File…", bundle: .module)
      case .installApp: LocalizedStringResource("Install App…", bundle: .module)
      case .openShell: LocalizedStringResource("Open Shell", bundle: .module)
      case .useOverWiFi: LocalizedStringResource("Use over Wi-Fi", bundle: .module)
      case .forget: LocalizedStringResource("Forget", bundle: .module)
      case .howToTurnOnFileTransfer:
        LocalizedStringResource("How to Turn On File Transfer", bundle: .module)
      case .mount: LocalizedStringResource("Mount", bundle: .module)
      case .checkAgain: LocalizedStringResource("Check Again", bundle: .module)
      case .eject: LocalizedStringResource("Eject", bundle: .module)
      case .connectAgain: LocalizedStringResource("Connect Again", bundle: .module)
      case .useIt: LocalizedStringResource("Use It", bundle: .module)
      case .ignore: LocalizedStringResource("Ignore", bundle: .module)
      }
    }

    var symbol: String {
      switch self {
      case .takeScreenshot: "camera"
      case .recordScreen: "video"
      case .stopRecording: "stop.circle"
      case .logcat: "doc.text"
      case .deviceInfo: "info.circle"
      case .portForwarding: "arrow.left.arrow.right"
      case .sendFile: "paperplane"
      case .installApp: "arrow.down.app"
      case .openShell: "terminal"
      case .useOverWiFi, .connectAgain, .useIt: "wifi"
      case .forget, .ignore: "xmark.circle"
      case .howToTurnOnFileTransfer: "questionmark.circle"
      case .mount: "externaldrive"
      case .checkAgain: "arrow.clockwise"
      case .eject: "eject"
      }
    }
  }

  /// The rows a device's expansion lists, in menu order: the ADB tools, Send File…, the network
  /// rows, the one its state needs, then Eject.
  static func actions(
    for device: AttachedDevice, isRemembered: Bool, recording: RecordingPhase
  ) -> [MenuAction] {
    var actions: [MenuAction] = []
    if offersTools(device) {
      actions.append(.takeScreenshot)
      switch recording {
      case .none: actions.append(.recordScreen)
      case .running: actions.append(.stopRecording)
      case .saving, .unsaved: break
      }
      actions += [.logcat, .deviceInfo, .portForwarding]
    }
    // Sending is a file write through the agent, so any method serves it.
    if case .ready = device.state { actions.append(.sendFile) }
    if offersTools(device) { actions += [.installApp, .openShell] }
    if offersWiFi(device) { actions.append(.useOverWiFi) }
    if isRemembered { actions.append(.forget) }
    switch device.state {
    case .ready:
      actions.append(.eject)
    case .notSharingFiles:
      if needsFileTransferSteps(device) { actions.append(.howToTurnOnFileTransfer) }
    case .ejected:
      actions.append(.mount)
    case .busy, .failed:
      actions.append(.checkAgain)
    }
    return actions
  }

  static let rememberedActions: [MenuAction] = [.connectAgain, .forget]
  static let offerActions: [MenuAction] = [.useIt, .ignore]
}

extension DevicePresentation {
  /// Where the device's recording has got, as the agent last said, and whether the app could
  /// not save it.
  static func recordingPhase(_ recording: ActiveRecording?, unsaved: Bool) -> RecordingPhase {
    guard let recording else { return .none }
    if recording.finished, unsaved { return .unsaved }
    return recording.stopping || recording.finished ? .saving : .running
  }

  /// The name an offered address claims, made safe to show.
  static func offerName(_ offer: UnconfirmedAddress) -> String {
    offer.name.isEmpty
      ? String(localized: LocalizedStringResource("Unknown device", bundle: .module))
      : DisplayText.escaped(offer.name)
  }
}
