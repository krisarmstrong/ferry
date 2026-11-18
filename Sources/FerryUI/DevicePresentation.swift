import DeviceKit
import Foundation

extension AttachedDevice {
  /// The model as the device reports it, made safe to show: a hostile device can name itself
  /// with control characters or bidi overrides.
  public var displayName: String {
    let name = info.model.isEmpty ? info.manufacturer : info.model
    return name.isEmpty
      ? String(localized: LocalizedStringResource("Unknown device", bundle: .module))
      : DisplayText.escaped(name)
  }
}

/// Text the menu shows for device states and errors.
enum DevicePresentation {
  static func status(of state: DeviceState) -> LocalizedStringResource {
    switch state {
    case .ready: LocalizedStringResource("Ready", bundle: .module)
    case .notSharingFiles: LocalizedStringResource("Not sharing files", bundle: .module)
    case .busy: LocalizedStringResource("In use by another app", bundle: .module)
    case .failed: LocalizedStringResource("Can't open", bundle: .module)
    }
  }

  static func storageLine(_ storage: StorageInfo) -> String {
    let free = storage.free.formatted(.byteCount(style: .file))
    let name = DisplayText.escaped(storage.description)
    return String(localized: LocalizedStringResource("\(name) · \(free) free", bundle: .module))
  }

  /// A short explanation of an agent error. Device-supplied detail is escaped.
  static func message(for error: TransportError) -> LocalizedStringResource {
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
    case .notFound, .unknownItem, .alreadyExists, .invalidName, .insufficientSpace,
      .fileTooLargeForStorage, .sizeMismatch, .nameChangedByDevice:
      LocalizedStringResource("The device reported an error.", bundle: .module)
    }
  }

  /// The state's name for logs, which carries no device-supplied text.
  static func kind(of state: DeviceState) -> String {
    switch state {
    case .ready(let storages): "ready(\(storages.count))"
    case .notSharingFiles: "notSharingFiles"
    case .busy: "busy"
    case .failed: "failed"
    }
  }
}
