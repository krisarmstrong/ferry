import DeviceKit
import FerryIPC
import Foundation

/// The text the menu app and the Finder Sync extension both show: agent and tool errors, device
/// names, and which devices offer the tools. A small module of its own, so the extension, which
/// runs in every Finder window, links this and its strings rather than the whole menu UI.
public enum PresentationText {
  /// Whether a device reached this way offers the tools (installing apps among them): over ADB,
  /// by USB or the network.
  public static func offersTools(_ method: ConnectionMethod) -> Bool {
    toolMethods.contains(method)
  }

  /// A short explanation of an agent error. Device-supplied detail is escaped, and the result
  /// is shown verbatim so the detail is never parsed as Markdown.
  public static func message(for error: TransportError) -> String {
    String(localized: resource(for: error))
  }

  /// The catalog key of `error`'s message, which names its entry in Help.
  public static func helpKey(for error: TransportError) -> String {
    resource(for: error).key
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

  public static func message(for failure: ToolFailure) -> String {
    String(localized: resource(for: failure))
  }

  /// The catalog key of `failure`'s message, which names its entry in Help.
  public static func helpKey(for failure: ToolFailure) -> String {
    resource(for: failure).key
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
        "The recording stopped arriving. It's still on the device: choose a folder, or discard it.",
        bundle: .module)
    case .recordingBusy:
      LocalizedStringResource(
        "The recording is still being finished. Try again in a moment.", bundle: .module)
    case .cannotSave:
      LocalizedStringResource(
        "Ferry can't save to its folder in Documents. Allow Ferry in Privacy & Security.",
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
      LocalizedStringResource(
        "Ferry can't find adb. Get it from the Ferry menu, then try again.", bundle: .module)
    case .forwardNotFound:
      LocalizedStringResource("That forward is already gone.", bundle: .module)
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
  public static func installFailure(_ reason: String) -> String {
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
  public static let toolMethods: Set<ConnectionMethod> = [.usbADB, .wifiADB]

  /// Whether a file the user picked or dropped is offered to the agent as an app. The agent
  /// checks its contents.
  public static func isAPK(_ url: URL) -> Bool {
    url.isFileURL && url.pathExtension.lowercased() == "apk"
  }

  /// What each device is called, made safe to show (a hostile device can name itself with
  /// control characters or bidi overrides), with the end of its serial where another device has
  /// the same name: the name its Finder location has.
  public static func shownNames(_ devices: [(id: DeviceID, name: String)]) -> [DeviceID: String] {
    let suffixes = DeviceNames.suffixes(for: devices)
    var names: [DeviceID: String] = [:]
    for device in devices {
      names[device.id] = DeviceNames.named(
        shownName(device.name), suffix: suffixes[device.id].map(DisplayText.escaped))
    }
    return names
  }

  /// A device-supplied name made safe to show, or "Unknown device" when there is none.
  public static func shownName(_ name: String) -> String {
    name.isEmpty
      ? String(localized: LocalizedStringResource("Unknown device", bundle: .module))
      : DisplayText.escaped(name)
  }
}
