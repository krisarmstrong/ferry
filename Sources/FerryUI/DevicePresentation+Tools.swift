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
    switch failure {
    case .notOverADB:
      String(
        localized: LocalizedStringResource(
          "This needs USB debugging. Turn it on, then try again.", bundle: .module))
    case .notAnAPK:
      String(
        localized: LocalizedStringResource(
          "That file isn't an Android app (.apk).", bundle: .module))
    case .apkTooLarge:
      String(
        localized: LocalizedStringResource("That app is larger than 4 GB.", bundle: .module))
    case .installFailed(let reason):
      installFailure(reason)
    case .alreadyRecording:
      String(
        localized: LocalizedStringResource(
          "The device is already recording its screen.", bundle: .module))
    case .notRecording:
      String(
        localized: LocalizedStringResource(
          "The device isn't recording its screen.", bundle: .module))
    case .noImage:
      String(
        localized: LocalizedStringResource(
          "The device didn't send a screenshot. Unlock it and try again.", bundle: .module))
    case .recordingFailed(let detail):
      recordingFailure(detail)
    case .recordingTooLarge:
      String(
        localized: LocalizedStringResource(
          "The device sent more than a recording can be, so Ferry deleted it.", bundle: .module))
    case .recordingStalled:
      String(
        localized: LocalizedStringResource(
          "The device stopped sending the recording, so Ferry deleted it.", bundle: .module))
    case .recordingBusy:
      String(
        localized: LocalizedStringResource(
          "The recording is still being finished. Try again in a moment.", bundle: .module))
    case .cannotSave:
      String(
        localized: LocalizedStringResource(
          "Ferry can't save to your screenshot folder or the Desktop. Allow Ferry in Privacy & Security.",
          bundle: .module))
    }
  }

  private static func recordingFailure(_ detail: String) -> String {
    if detail.isEmpty {
      return String(
        localized: LocalizedStringResource("The device didn't record its screen.", bundle: .module))
    }
    let shown = DisplayText.escaped(detail)
    return String(
      localized: LocalizedStringResource(
        "The device didn't record its screen: \(shown)", bundle: .module))
  }

  /// pm's refusal in plain words where the code is a common one; otherwise the code (or pm's
  /// line), escaped, since the device wrote it.
  static func installFailure(_ reason: String) -> String {
    if let known = installReasons[reason] { return String(localized: known) }
    if reason.hasPrefix("INSTALL_PARSE_FAILED_") {
      return String(
        localized: LocalizedStringResource(
          "The app couldn't be read by the device. It may be damaged or unsigned.",
          bundle: .module))
    }
    let shown = DisplayText.escaped(reason)
    return String(
      localized: LocalizedStringResource("Couldn't install the app: \(shown)", bundle: .module))
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
