import DeviceKit
import FerryIPC
import Foundation

/// Text the menu shows for the ADB tools.
extension DevicePresentation {
  /// Tools are offered on a device Ferry serves over ADB, by USB or the network.
  static func offersTools(_ device: AttachedDevice) -> Bool {
    if case .ready = device.state { [.usbADB, .wifiADB].contains(device.method) } else { false }
  }

  /// Whether a file the user picked or dropped is offered to the agent as an app. The agent
  /// checks its contents.
  static func isAPK(_ url: URL) -> Bool {
    url.isFileURL && url.pathExtension.lowercased() == "apk"
  }

  /// An app on its way to the device: its name, escaped since the user's file named it, and how
  /// far it has got. At 100% the device is installing it.
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

  static func message(for failure: ToolFailure) -> String {
    String(localized: resource(for: failure))
  }

  private static func resource(for failure: ToolFailure) -> LocalizedStringResource {
    switch failure {
    case .notOverADB:
      LocalizedStringResource(
        "This needs USB debugging. Turn it on, then try again.", bundle: .module)
    case .notAnAPK:
      LocalizedStringResource("That file isn't an Android app (.apk).", bundle: .module)
    case .apkTooLarge:
      LocalizedStringResource("That app is larger than 4 GB.", bundle: .module)
    case .installFailed(let reason):
      installFailureResource(reason)
    case .alreadyRecording:
      LocalizedStringResource("The device is already recording its screen.", bundle: .module)
    case .notRecording:
      LocalizedStringResource("The device isn't recording its screen.", bundle: .module)
    case .noImage:
      LocalizedStringResource(
        "The device didn't send a screenshot. Unlock it and try again.", bundle: .module)
    case .recordingFailed(let detail):
      recordingFailure(detail)
    case .recordingTooLarge:
      LocalizedStringResource(
        "The device sent more than a recording can be, so Ferry deleted it.", bundle: .module)
    case .recordingStalled:
      LocalizedStringResource(
        "The device stopped sending the recording, so Ferry deleted it.", bundle: .module)
    case .recordingBusy:
      LocalizedStringResource(
        "The recording is still being finished. Try again in a moment.", bundle: .module)
    case .cannotSave:
      LocalizedStringResource(
        "Ferry can't save to your screenshot folder or the Desktop. Allow Ferry in Privacy & Security.",
        bundle: .module)
    case .invalidPort:
      LocalizedStringResource(
        "Use a port from 1024 to 65535 on this Mac and from 1 to 65535 on the device.",
        bundle: .module)
    case .forwardFailed(let detail):
      // adb's own words, escaped, since a device or a program wrote them.
      LocalizedStringResource(
        "adb couldn't forward the port: \(DisplayText.escaped(detail))", bundle: .module)
    case .adbNotFound:
      LocalizedStringResource("Ferry can't find adb. Install it, then try again.", bundle: .module)
    }
  }

  private static func recordingFailure(_ detail: String) -> LocalizedStringResource {
    if detail.isEmpty {
      return LocalizedStringResource("The device didn't record its screen.", bundle: .module)
    }
    let shown = DisplayText.escaped(detail)
    return LocalizedStringResource(
      "The device didn't record its screen: \(shown)", bundle: .module)
  }

  /// pm's refusal in plain words where the code is a common one; otherwise the code (or pm's
  /// line), escaped, since the device wrote it.
  static func installFailure(_ reason: String) -> String {
    String(localized: installFailureResource(reason))
  }

  private static func installFailureResource(_ reason: String) -> LocalizedStringResource {
    if let known = installReasons[reason] { return known }
    if reason.hasPrefix("INSTALL_PARSE_FAILED_") {
      return LocalizedStringResource(
        "The app couldn't be read by the device. It may be damaged or unsigned.", bundle: .module)
    }
    let shown = DisplayText.escaped(reason)
    return LocalizedStringResource("Couldn't install the app: \(shown)", bundle: .module)
  }

  private static let installReasons: [String: LocalizedStringResource] = [
    "INSTALL_FAILED_ALREADY_EXISTS": LocalizedStringResource(
      "The app is already installed.", bundle: .module),
    "INSTALL_FAILED_INSUFFICIENT_STORAGE": LocalizedStringResource(
      "The device doesn't have enough space for the app.", bundle: .module),
    "INSTALL_FAILED_VERSION_DOWNGRADE": LocalizedStringResource(
      "A newer version of the app is installed. Uninstall it first.", bundle: .module),
    "INSTALL_FAILED_UPDATE_INCOMPATIBLE": LocalizedStringResource(
      "The installed app is signed differently. Uninstall it first.", bundle: .module),
    "INSTALL_FAILED_OLDER_SDK": LocalizedStringResource(
      "The app needs a newer version of Android.", bundle: .module),
    "INSTALL_FAILED_NO_MATCHING_ABIS": LocalizedStringResource(
      "The app doesn't support this device's processor.", bundle: .module),
    "INSTALL_FAILED_TEST_ONLY": LocalizedStringResource(
      "The app is a test build, which the device won't install.", bundle: .module),
    "INSTALL_FAILED_DUPLICATE_PERMISSION": LocalizedStringResource(
      "Another app on the device already defines one of this app's permissions.",
      bundle: .module),
    "INSTALL_FAILED_CONFLICTING_PROVIDER": LocalizedStringResource(
      "Another app on the device already uses this app's content provider.", bundle: .module),
    "INSTALL_FAILED_MISSING_SHARED_LIBRARY": LocalizedStringResource(
      "The app needs a library the device doesn't have.", bundle: .module),
    "INSTALL_FAILED_INVALID_APK": LocalizedStringResource(
      "The app couldn't be read by the device. It may be damaged or unsigned.", bundle: .module),
    "INSTALL_FAILED_USER_RESTRICTED": LocalizedStringResource(
      "The device doesn't allow installing apps over USB.", bundle: .module),
    "INSTALL_FAILED_VERIFICATION_FAILURE": LocalizedStringResource(
      "The device's app verification refused the app.", bundle: .module),
    "INSTALL_FAILED_ABORTED": LocalizedStringResource(
      "The install was cancelled on the device.", bundle: .module),
  ]
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
        "— \(count) lines skipped, the log came faster than Ferry could show it —",
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
    String(localized: LocalizedStringResource("\(shown) of \(held) lines", bundle: .module))
  }

  /// A window title: the tool, then the device's model (escaped, the device named itself).
  static func logTitle(model: String) -> String {
    windowTitle(LocalizedStringResource("Logcat", bundle: .module), model)
  }

  static func forwardsTitle(model: String) -> String {
    windowTitle(LocalizedStringResource("Port Forwarding", bundle: .module), model)
  }

  static func infoTitle(model: String) -> String {
    windowTitle(LocalizedStringResource("Device Info", bundle: .module), model)
  }

  private static func windowTitle(_ tool: LocalizedStringResource, _ model: String) -> String {
    let name = String(localized: tool)
    return model.isEmpty ? name : "\(name) · \(DisplayText.escaped(model))"
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
      info.addresses.map(DisplayText.escaped).joined(separator: ", "))
    if let storage = info.storage {
      add(LocalizedStringResource("Storage", bundle: .module), storageLine(storage))
    }
    return rows
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
