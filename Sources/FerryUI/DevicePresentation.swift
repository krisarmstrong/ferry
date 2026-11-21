import DeviceKit
import FerryIPC
import FerryText
import Foundation

extension AppModel {
  /// What the menu calls `device` (see `PresentationText.shownNames(_:)`).
  public func displayName(of device: AttachedDevice) -> String {
    PresentationText.shownNames(devices.map { ($0.id, $0.info.name) })[device.id]
      ?? PresentationText.shownName(device.info.name)
  }
}

/// Text the menu shows for device states and errors. Agent and tool errors are worded in
/// `PresentationText`, which the Finder Sync extension shares.
enum DevicePresentation {
  static func message(for error: TransportError) -> String {
    PresentationText.message(for: error)
  }

  static func message(for failure: ToolFailure) -> String {
    PresentationText.message(for: failure)
  }

  /// `error`'s message, with its entry in Help.
  static func notice(for error: TransportError) -> MenuNotice {
    MenuNotice(text: message(for: error), help: PresentationText.helpKey(for: error))
  }

  static func notice(for failure: ToolFailure) -> MenuNotice {
    MenuNotice(text: message(for: failure), help: PresentationText.helpKey(for: failure))
  }

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

  /// What a network request ended with, for the user, with its entry in Help; `nil` when it
  /// connected. adb's own words are escaped.
  static func notice(for outcome: WirelessOutcome) -> MenuNotice? {
    switch outcome {
    case .connected:
      nil
    case .awaitingAllow:
      MenuNotice(
        LocalizedStringResource("Tap Allow on the device to finish connecting.", bundle: .module))
    case .needsConfirmation:
      MenuNotice(
        LocalizedStringResource(
          "Ferry knows this device at another address. Confirm the new one in the menu.",
          bundle: .module))
    case .needsNetwork:
      MenuNotice(
        LocalizedStringResource(
          "The device has no network address. Connect it to Ethernet or Wi-Fi first.",
          bundle: .module))
    case .failed(let failure):
      MenuNotice(resource(for: failure))
    }
  }

  private static func resource(for failure: WirelessFailure) -> LocalizedStringResource {
    switch failure {
    case .adbUnavailable:
      LocalizedStringResource(
        "adb isn't available. Use the adb line at the top of the menu.", bundle: .module)
    case .notOverUSB:
      LocalizedStringResource(
        "Connect the device with a cable and allow USB debugging first.", bundle: .module)
    case .notRemembered:
      LocalizedStringResource(
        "Ferry has no address for this device. Connect it by address.", bundle: .module)
    case .noConnectService:
      LocalizedStringResource(
        "Paired, but the device isn't offering a connection. Check Wireless debugging is on.",
        bundle: .module)
    case .otherDevice:
      LocalizedStringResource("That address belongs to another device.", bundle: .module)
    case .unidentified:
      LocalizedStringResource(
        "The device didn't say which device it is, so Ferry disconnected it.", bundle: .module)
    case .pairingNeedsAddress:
      LocalizedStringResource(
        "Use the IP address the device shows under Pair device with pairing code.",
        bundle: .module)
    case .offerChanged:
      LocalizedStringResource(
        "That address changed. Check the menu and try again.", bundle: .module)
    case .deviceInUse:
      LocalizedStringResource(
        """
        Ferry is using this device. Wait for its transfers, screen recording and log to \
        finish, then try again.
        """, bundle: .module)
    case .serverRestarted:
      LocalizedStringResource(
        "adb had lost network access, so Ferry restarted it. Try again in a moment.",
        bundle: .module)
    case .localNetworkDenied:
      LocalizedStringResource(
        """
        Ferry needs Local Network access to reach devices over Wi-Fi. Turn it on in System \
        Settings › Privacy & Security › Local Network.
        """, bundle: .module)
    case .adb(let detail):
      LocalizedStringResource("adb: \(DisplayText.escaped(detail))", bundle: .module)
    }
  }

  /// A network device waiting for the user to allow this Mac on it. The address comes from
  /// adb's listing, so it is escaped.
  static func waitingLine(for address: String) -> MenuNotice {
    let address = DisplayText.escaped(address)
    return MenuNotice(
      LocalizedStringResource("Waiting for you to allow this Mac on \(address)", bundle: .module))
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
