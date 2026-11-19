import DeviceKit
import FerryIPC
import FerryText
import Foundation

/// Text the menu shows for the ADB tools.
extension DevicePresentation {
  /// Tools are offered on a device Ferry serves over ADB, by USB or the network.
  static func offersTools(_ device: AttachedDevice) -> Bool {
    if case .ready = device.state {
      PresentationText.toolMethods.contains(device.method)
    } else {
      false
    }
  }

  /// An app on its way to the device: its name, escaped since the user's file named it, and how
  /// far it has got. At 100% the device is installing it.
  /// Cancel is offered while the app is still being copied: once the device is installing it,
  /// the install finishes.
  static func offersCancel(_ install: AppInstall) -> Bool {
    install.percent < 100
  }

  static func installingLine(_ install: AppInstall) -> String {
    let name = DisplayText.escaped(install.name)
    if install.percent >= 100 {
      return String(localized: LocalizedStringResource("Installing “\(name)”…", bundle: .module))
    }
    let percent = install.percent
    return String(
      localized: LocalizedStringResource(
        "Copying “\(name)” to the device · \(percent)%", bundle: .module))
  }

  static func installedLine(_ name: String) -> String {
    let name = DisplayText.escaped(name)
    return String(localized: LocalizedStringResource("Installed “\(name)”.", bundle: .module))
  }

}

/// Text for the developer tools: the log window, Device Info.
extension DevicePresentation {
  struct InfoRow: Equatable {
    let label: String
    let value: String
  }

  static var logEndedLine: String {
    String(localized: LocalizedStringResource("The device ended the log.", bundle: .module))
  }

  static func skippedLinesLine(_ count: Int) -> String {
    String(
      localized: LocalizedStringResource(
        "— Lines skipped: \(count). The log came faster than Ferry could show it. —",
        bundle: .module))
  }

  static func saveLogFailure(_ reason: String) -> String {
    let shown = DisplayText.escaped(reason)
    return String(
      localized: LocalizedStringResource("Couldn't save the log: \(shown)", bundle: .module))
  }

  static var terminalFailure: String {
    String(localized: LocalizedStringResource("Ferry couldn't open Terminal.", bundle: .module))
  }

  static func logCountLine(shown: Int, held: Int) -> String {
    String(localized: LocalizedStringResource("Lines shown: \(shown) of \(held)", bundle: .module))
  }

  /// A window title: the tool, then the device as the menu names it (`name`, already escaped:
  /// the device named itself).
  static func logTitle(name: String) -> String {
    windowTitle(LocalizedStringResource("Logcat", bundle: .module), name)
  }

  static func forwardsTitle(name: String) -> String {
    windowTitle(LocalizedStringResource("Port Forwarding", bundle: .module), name)
  }

  static func infoTitle(name: String) -> String {
    windowTitle(LocalizedStringResource("Device Info", bundle: .module), name)
  }

  /// One format, so a language can put the device first.
  private static func windowTitle(_ tool: LocalizedStringResource, _ name: String) -> String {
    let tool = String(localized: tool)
    guard !name.isEmpty else { return tool }
    return String(localized: LocalizedStringResource("\(tool) · \(name)", bundle: .module))
  }

  /// A forward as the list shows it: the Mac port, an arrow, the device port.
  static func forwardLine(_ forward: PortForward) -> String {
    String(localized: forwardLineResource(forward))
  }

  /// Ports are interpolated as text: as numbers they would be grouped, `8,080`.
  static func forwardLineResource(_ forward: PortForward) -> LocalizedStringResource {
    let (local, remote) = (String(forward.local), String(forward.remote))
    return LocalizedStringResource(
      "This Mac port \(local) → device port \(remote)", bundle: .module)
  }

  /// What VoiceOver reads for a button every device row repeats: the action, then the device as
  /// the menu names it (already escaped), so two rows' Eject buttons can be told apart.
  static func actionLabel(_ action: LocalizedStringResource, on name: String) -> String {
    let action = String(localized: action)
    return String(localized: LocalizedStringResource("\(action), \(name)", bundle: .module))
  }

  static func removeForwardLabel(_ forward: PortForward) -> String {
    String(localized: removeForwardResource(forward))
  }

  static func removeForwardResource(_ forward: PortForward) -> LocalizedStringResource {
    let local = String(forward.local)
    return LocalizedStringResource("Remove the forward from port \(local)", bundle: .module)
  }

  /// What the device said about itself, a row each; a part it could not say has no row. Every
  /// value is the device's, so it is escaped.
  static func infoRows(_ info: AndroidDeviceInfo) -> [InfoRow] {
    var rows: [InfoRow] = []
    func add(_ label: LocalizedStringResource, _ value: String) {
      guard !value.isEmpty else { return }
      rows.append(InfoRow(label: String(localized: label), value: value))
    }
    add(LocalizedStringResource("Model", bundle: .module), DisplayText.escaped(info.model))
    add(
      LocalizedStringResource("Android version", bundle: .module),
      DisplayText.escaped(info.androidVersion))
    add(LocalizedStringResource("Build", bundle: .module), DisplayText.escaped(info.build))
    add(LocalizedStringResource("Serial number", bundle: .module), DisplayText.escaped(info.serial))
    if let battery = info.battery {
      add(LocalizedStringResource("Battery", bundle: .module), batteryLine(battery))
    }
    add(
      LocalizedStringResource("IP addresses", bundle: .module),
      info.addresses.map(addressLine).joined(separator: ", "))
    if let storage = info.storage {
      add(LocalizedStringResource("Storage", bundle: .module), storageLine(storage))
    }
    return rows
  }

  /// The address, then the kind of link it is on, or the interface's own name for any other.
  private static func addressLine(_ address: AndroidDeviceInfo.Address) -> String {
    let link =
      switch address.kind {
      case .wifi: String(localized: LocalizedStringResource("Wi-Fi", bundle: .module))
      case .ethernet: String(localized: LocalizedStringResource("Ethernet", bundle: .module))
      case .mobileData: String(localized: LocalizedStringResource("Mobile data", bundle: .module))
      case .usb: String(localized: LocalizedStringResource("USB", bundle: .module))
      case .other(let name): DisplayText.escaped(name)
      }
    let value = DisplayText.escaped(address.address)
    return String(localized: LocalizedStringResource("\(value) (\(link))", bundle: .module))
  }

  private static func batteryLine(_ battery: AndroidDeviceInfo.Battery) -> String {
    let level = battery.level
    return switch battery.state {
    case .charging:
      String(localized: LocalizedStringResource("\(level)%, charging", bundle: .module))
    case .discharging:
      String(localized: LocalizedStringResource("\(level)%, discharging", bundle: .module))
    case .notCharging:
      String(localized: LocalizedStringResource("\(level)%, not charging", bundle: .module))
    case .full:
      String(localized: LocalizedStringResource("\(level)%, full", bundle: .module))
    case .unknown:
      String(localized: LocalizedStringResource("\(level)%", bundle: .module))
    }
  }

  private static func storageLine(_ storage: AndroidDeviceInfo.Storage) -> String {
    let used = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: storage.used), countStyle: .file)
    let free = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: storage.free), countStyle: .file)
    return String(localized: LocalizedStringResource("\(used) used, \(free) free", bundle: .module))
  }
}
