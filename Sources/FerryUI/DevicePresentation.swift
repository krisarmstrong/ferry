import DeviceKit
import FerryIPC
import Foundation

extension DevicePresentation {
  /// What each device is called, made safe to show (a hostile device can name itself with
  /// control characters or bidi overrides), with the end of its serial where another device has
  /// the same name: the name its Finder location has.
  static func shownNames(_ devices: [(id: DeviceID, name: String)]) -> [DeviceID: String] {
    let suffixes = DeviceNames.suffixes(for: devices)
    var names: [DeviceID: String] = [:]
    for device in devices {
      names[device.id] = DeviceNames.named(
        shownName(device.name), suffix: suffixes[device.id].map(DisplayText.escaped))
    }
    return names
  }

  /// A device-supplied name made safe to show, or "Unknown device" when there is none.
  static func shownName(_ name: String) -> String {
    name.isEmpty
      ? String(localized: LocalizedStringResource("Unknown device", bundle: .module))
      : DisplayText.escaped(name)
  }
}

extension AppModel {
  /// What the menu calls `device` (see `DevicePresentation.shownNames(_:)`).
  public func displayName(of device: AttachedDevice) -> String {
    DevicePresentation.shownNames(devices.map { ($0.id, $0.info.name) })[device.id]
      ?? DevicePresentation.shownName(device.info.name)
  }
}

/// Text the menu shows for device states and errors.
enum DevicePresentation {
  /// The status word for `device`: one only adb lists, as unauthorised, waits for Allow rather
  /// than for file transfer.
  static func status(of device: AttachedDevice) -> LocalizedStringResource {
    if device.state == .notSharingFiles, device.method == .usbADB {
      return LocalizedStringResource("Waiting for Allow", bundle: .module)
    }
    return status(of: device.state)
  }

  static func status(of state: DeviceState) -> LocalizedStringResource {
    switch state {
    case .ready: LocalizedStringResource("Ready", bundle: .module)
    case .notSharingFiles: LocalizedStringResource("Not sharing files", bundle: .module)
    case .ejected: LocalizedStringResource("Ejected", bundle: .module)
    case .busy: LocalizedStringResource("In use by another app", bundle: .module)
    case .failed: LocalizedStringResource("Can't open", bundle: .module)
    }
  }

  /// How Ferry reaches the device, as the menu shows it under the device's name.
  static func method(_ method: ConnectionMethod) -> LocalizedStringResource {
    switch method {
    case .usbADB: LocalizedStringResource("USB · ADB", bundle: .module)
    case .wifiADB: LocalizedStringResource("Wi-Fi · ADB", bundle: .module)
    case .usbFileTransfer: LocalizedStringResource("USB · File transfer", bundle: .module)
    }
  }

  /// The method the menu shows for `device`: only a device Ferry is serving has one.
  static func shownMethod(of device: AttachedDevice) -> ConnectionMethod? {
    if case .ready = device.state { device.method } else { nil }
  }

  /// A line the menu adds under a device, with an action where it has one.
  enum Hint: Equatable {
    /// USB debugging is off; the guide turns it on for more tools.
    case moreTools
    /// USB debugging is on and waits for the user to allow this Mac on the device.
    case allowUSBDebugging
  }

  static func hint(for device: AttachedDevice, awaitingUSBDebugging: Bool) -> Hint? {
    switch device.state {
    case .ready, .notSharingFiles:
      if awaitingUSBDebugging { return .allowUSBDebugging }
      if case .ready = device.state, device.method == .usbFileTransfer { return .moreTools }
      return nil
    case .ejected, .busy, .failed:
      return nil
    }
  }

  /// Whether the device is waiting for file transfer. A device only adb lists, as unauthorised,
  /// shows as not sharing files too, but file transfer is not what it needs.
  static func needsFileTransferSteps(_ device: AttachedDevice) -> Bool {
    device.state == .notSharingFiles && device.method != .usbADB
  }

  static let installCommand = "brew install --cask android-platform-tools"

  /// Use over Wi-Fi is offered on a device Ferry serves over USB debugging.
  static func offersWiFi(_ device: AttachedDevice) -> Bool {
    if case .ready = device.state { device.method == .usbADB } else { false }
  }

  /// The name a remembered device reported, made safe to show.
  static func rememberedName(_ device: RememberedDevice) -> String {
    device.name.isEmpty
      ? String(localized: LocalizedStringResource("Unknown device", bundle: .module))
      : DisplayText.escaped(device.name)
  }

  /// The menu's question about an address that claims a known device. Both parts came from the
  /// network or the device, so both are escaped.
  static func confirmQuestion(_ offer: UnconfirmedAddress) -> String {
    let address = DisplayText.escaped(offer.address.argument)
    let name = DisplayText.escaped(offer.name)
    return String(
      localized: LocalizedStringResource("Is \(address) your \(name)?", bundle: .module))
  }

  /// What a network request ended with, for the user; `nil` when it connected. adb's own words
  /// are escaped.
  static func message(for outcome: WirelessOutcome) -> String? {
    switch outcome {
    case .connected:
      nil
    case .awaitingAllow:
      String(
        localized: LocalizedStringResource(
          "Tap Allow on the device to finish connecting.", bundle: .module))
    case .needsConfirmation:
      String(
        localized: LocalizedStringResource(
          "Ferry knows this device at another address. Confirm the new one in the menu.",
          bundle: .module))
    case .needsNetwork:
      String(
        localized: LocalizedStringResource(
          "The device has no network address. Connect it to Ethernet or Wi-Fi first.",
          bundle: .module))
    case .failed(let failure):
      message(for: failure)
    }
  }

  private static func message(for failure: WirelessFailure) -> String {
    switch failure {
    case .adbUnavailable:
      String(
        localized: LocalizedStringResource(
          "adb isn't running. Install it, or choose Check again.", bundle: .module))
    case .notOverUSB:
      String(
        localized: LocalizedStringResource(
          "Connect the device with a cable and allow USB debugging first.", bundle: .module))
    case .notRemembered:
      String(
        localized: LocalizedStringResource(
          "Ferry has no address for this device. Connect it by address.", bundle: .module))
    case .noConnectService:
      String(
        localized: LocalizedStringResource(
          "Paired, but the device isn't offering a connection. Check Wireless debugging is on.",
          bundle: .module))
    case .otherDevice:
      String(
        localized: LocalizedStringResource(
          "That address belongs to another device.", bundle: .module))
    case .unidentified:
      String(
        localized: LocalizedStringResource(
          "The device didn't say which device it is, so Ferry disconnected it.", bundle: .module))
    case .pairingNeedsAddress:
      String(
        localized: LocalizedStringResource(
          "Use the IP address the device shows under Pair device with pairing code.",
          bundle: .module))
    case .offerChanged:
      String(
        localized: LocalizedStringResource(
          "That address changed. Check the menu and try again.", bundle: .module))
    case .adb(let detail):
      String(
        localized: LocalizedStringResource(
          "adb: \(DisplayText.escaped(detail))", bundle: .module))
    }
  }

  /// A network device waiting for the user to allow this Mac on it. The address comes from
  /// adb's listing, so it is escaped.
  static func waitingLine(for address: String) -> String {
    let address = DisplayText.escaped(address)
    return String(
      localized: LocalizedStringResource(
        "Waiting for you to allow this Mac on \(address)", bundle: .module))
  }

  static func storageLine(_ storage: StorageInfo) -> String {
    let free = storage.free.formatted(.byteCount(style: .file))
    let name = DisplayText.escaped(storage.description)
    return String(localized: LocalizedStringResource("\(name) · \(free) free", bundle: .module))
  }

  /// A running transfer: the item's name, escaped since the device or the user chose it, where
  /// it is going and how far it has got.
  static func transferLine(_ transfer: ActiveTransfer) -> String {
    let name = DisplayText.escaped(transfer.name)
    let percent = transfer.percent
    return switch transfer.direction {
    case .toDevice:
      String(
        localized: LocalizedStringResource(
          "Copying “\(name)” to the device · \(percent)%", bundle: .module))
    case .toMac:
      String(
        localized: LocalizedStringResource(
          "Copying “\(name)” to this Mac · \(percent)%", bundle: .module))
    }
  }

  /// A short explanation of an agent error. Device-supplied detail is escaped, and the result
  /// is shown verbatim so the detail is never parsed as Markdown.
  static func message(for error: TransportError) -> String {
    String(localized: resource(for: error))
  }

  private static func resource(for error: TransportError) -> LocalizedStringResource {
    switch error {
    case .deviceBusy:
      LocalizedStringResource(
        "Another app is using the device. Quit Image Capture or Android File Transfer.",
        bundle: .module)
    case .deviceLocked:
      LocalizedStringResource("The device is not sharing files.", bundle: .module)
    case .deviceDisconnected, .deviceNotFound, .noDeviceConnected:
      LocalizedStringResource("The device was disconnected.", bundle: .module)
    case .noStorage, .storageNotFound:
      LocalizedStringResource("The device reports no storage.", bundle: .module)
    case .unsupported(let what):
      LocalizedStringResource(
        "The device does not support this: \(DisplayText.escaped(what)).", bundle: .module)
    case .io(let detail):
      LocalizedStringResource("Error: \(DisplayText.escaped(detail))", bundle: .module)
    case .cancelled:
      LocalizedStringResource("Cancelled.", bundle: .module)
    case .agentNotResponding:
      LocalizedStringResource(
        "Ferry's helper didn't answer in time. Try again in a moment.", bundle: .module)
    case .notFound, .unknownItem, .alreadyExists, .invalidName, .insufficientSpace,
      .fileTooLargeForStorage, .sizeMismatch, .downloadSizeMismatch, .nameChangedByDevice,
      .directoryNotEmpty, .changedOnDevice, .macDiskFull, .folderTooDeep, .readOnly:
      LocalizedStringResource("The device reported an error.", bundle: .module)
    }
  }

  /// The state's name for logs, which carries no device-supplied text.
  static func kind(of state: DeviceState) -> String {
    switch state {
    case .ready(let storages): "ready(\(storages.count))"
    case .notSharingFiles: "notSharingFiles"
    case .ejected: "ejected"
    case .busy: "busy"
    case .failed: "failed"
    }
  }
}
