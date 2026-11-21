import DeviceKit
import FerryIPC
import FerryText
import Foundation

/// What each row of the menu shows and offers: a round tile, a one-line summary under the name,
/// and the actions its expansion lists.
extension DevicePresentation {
  /// The round tile at the start of a row: what kind of device it is, filled with the accent
  /// colour while Ferry serves the device and neutral otherwise. How Ferry reaches it is the
  /// first word of the summary under its name.
  struct Tile: Equatable {
    let glyph: TileGlyph
    let isActive: Bool
  }

  /// What a tile draws.
  enum TileGlyph: Equatable {
    case phone
    /// A handheld network tester, drawn by `DeviceGlyph`.
    case tester
    /// Drawn by `DeviceGlyph`: SF Symbols' tablets are all iPads.
    case tablet
    case symbol(String)

    /// The SF Symbol a phone is drawn with.
    static let phoneSymbol = "smartphone"
  }

  static func tile(of device: AttachedDevice) -> Tile {
    let glyph = kind(manufacturer: device.info.manufacturer, model: device.info.model)
    if case .ready = device.state { return Tile(glyph: glyph, isActive: true) }
    return Tile(glyph: glyph, isActive: false)
  }

  static let rememberedTile = Tile(glyph: .symbol("wifi.slash"), isActive: false)
  static let offerTile = Tile(glyph: .symbol("wifi"), isActive: false)

  /// NetAlly's Android testers, by the start of their model names (lowercased, letters and
  /// digits only, any leading "netally" dropped).
  private static let testerModels = ["linkrunner", "etherscope", "aircheck", "cyberscope"]

  /// Words in a model name that make it a tablet.
  private static let tabletWords: Set<Substring> = ["tablet", "tab", "pad", "matepad", "mediapad"]

  /// What kind of device reports this manufacturer and model. Only names decide it: a tester by
  /// its model or its maker; a tablet by a "tablet", "tab", "pad", "matepad" or "mediapad" word
  /// in its name, or, from their makers only, Samsung's tablet model numbers (SM-T, SM-X, SM-P),
  /// Lenovo's (TB) and Amazon's Fire tablets (KF, or "fire"); anything else is a phone.
  static func kind(manufacturer: String, model: String) -> TileGlyph {
    let maker = manufacturer.lowercased()
    var key = String(
      String.UnicodeScalarView(
        model.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    if key.hasPrefix("netally") { key.removeFirst("netally".count) }
    if maker == "netally" || testerModels.contains(where: key.hasPrefix) { return .tester }
    let words = model.lowercased().split { !$0.isLetter && !$0.isNumber }
    if words.contains(where: tabletWords.contains) { return .tablet }
    // Model numbers, without a leading maker name ("Lenovo TB-X606F").
    var code = model.uppercased()
    if code.hasPrefix(manufacturer.uppercased() + " ") { code.removeFirst(manufacturer.count + 1) }
    switch maker {
    case "samsung" where ["SM-T", "SM-X", "SM-P"].contains(where: code.hasPrefix): return .tablet
    case "lenovo" where code.hasPrefix("TB"): return .tablet
    case "amazon" where code.hasPrefix("KF") || words.contains("fire"): return .tablet
    default: break
    }
    return .phone
  }

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
    case takeScreenshot, recordScreen, stopRecording, logcat, portForwarding, sendFile, installApp
    case openInTerminal, useOverWiFi, forget, howToTurnOnFileTransfer, mount, checkAgain, eject
    case connectAgain, useIt, ignore

    var title: LocalizedStringResource {
      switch self {
      case .takeScreenshot: LocalizedStringResource("Take Screenshot", bundle: .module)
      case .recordScreen: LocalizedStringResource("Record Screen", bundle: .module)
      case .stopRecording: LocalizedStringResource("Stop Recording", bundle: .module)
      case .logcat: LocalizedStringResource("Logcat", bundle: .module)
      case .portForwarding: LocalizedStringResource("Port Forwarding", bundle: .module)
      case .sendFile: LocalizedStringResource("Send File…", bundle: .module)
      case .installApp: LocalizedStringResource("Install App…", bundle: .module)
      case .openInTerminal: LocalizedStringResource("Open in Terminal", bundle: .module)
      case .useOverWiFi: LocalizedStringResource("Use over Wi-Fi", bundle: .module)
      case .forget: LocalizedStringResource("Forget This Device", bundle: .module)
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
      case .portForwarding: "arrow.left.arrow.right"
      case .sendFile: "paperplane"
      case .installApp: "arrow.down.app"
      case .openInTerminal: "terminal"
      case .useOverWiFi, .connectAgain, .useIt: "wifi"
      case .forget, .ignore: "xmark.circle"
      case .howToTurnOnFileTransfer: "questionmark.circle"
      case .mount: "externaldrive"
      case .checkAgain: "arrow.clockwise"
      case .eject: "eject"
      }
    }
  }

  /// The rows a device's expansion lists under its details, in groups the menu divides with
  /// thin lines: capture, sending, the developer tools, then the device itself (Use over Wi-Fi,
  /// Forget This Device, and Eject or the row its state needs). A group with no rows is left out.
  static func actionGroups(
    for device: AttachedDevice, isRemembered: Bool, recording: RecordingPhase
  ) -> [[MenuAction]] {
    let tools = offersTools(device)
    var capture: [MenuAction] = []
    var sending: [MenuAction] = []
    var developer: [MenuAction] = []
    var own: [MenuAction] = []
    if tools {
      capture.append(.takeScreenshot)
      switch recording {
      case .none: capture.append(.recordScreen)
      case .running: capture.append(.stopRecording)
      case .saving, .unsaved: break
      }
      developer = [.logcat, .portForwarding, .openInTerminal]
    }
    // Sending is a file write through the agent, so any method serves it.
    if case .ready = device.state { sending.append(.sendFile) }
    if tools { sending.append(.installApp) }
    if offersWiFi(device) { own.append(.useOverWiFi) }
    if isRemembered { own.append(.forget) }
    switch device.state {
    case .ready:
      own.append(.eject)
    case .notSharingFiles:
      if needsFileTransferSteps(device) { own.append(.howToTurnOnFileTransfer) }
    case .ejected:
      own.append(.mount)
    case .busy, .failed:
      own.append(.checkAgain)
    }
    return [capture, sending, developer, own].filter { !$0.isEmpty }
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
