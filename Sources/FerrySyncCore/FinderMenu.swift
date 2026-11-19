import DeviceKit
import FerryUI
import Foundation

/// What a Finder menu item does.
public enum FinderAction: Hashable, Sendable {
  /// Sends the selected files into the device's `Download/` folder.
  case send(DeviceID)
  /// Installs the selected apps on the device.
  case install(DeviceID)

  public var device: DeviceID {
    switch self {
    case .send(let id), .install(let id): id
    }
  }
}

/// One line of the Finder menu. A line with no action is shown disabled.
public struct FinderMenuEntry: Equatable, Sendable {
  public let title: String
  public let action: FinderAction?

  public init(title: String, action: FinderAction?) {
    self.title = title
    self.action = action
  }
}

/// Builds Ferry's Finder menu, for the context menu of selected items and the toolbar item.
public enum FinderMenu {
  /// A Send line for each device that can take a file, then an Install line for each of those
  /// served over ADB when every selected item is an app. Sending is a file write through the
  /// agent, so any method serves it; installing needs ADB.
  public static func entries(devices: [AttachedDevice], selection: [URL]) -> [FinderMenuEntry] {
    let ready = devices.filter(canReceive)
    guard !ready.isEmpty else {
      return [FinderMenuEntry(title: text("No device connected"), action: nil)]
    }
    guard !selection.isEmpty else {
      return [FinderMenuEntry(title: text("Select files to send"), action: nil)]
    }
    var entries = ready.map { device in
      let name = displayName(of: device)
      return FinderMenuEntry(
        title: String(localized: LocalizedStringResource("Send to \(name)", bundle: .module)),
        action: .send(device.id))
    }
    if selection.allSatisfy(PresentationText.isAPK) {
      entries += ready.filter(PresentationText.offersTools).map { device in
        let name = displayName(of: device)
        return FinderMenuEntry(
          title: String(localized: LocalizedStringResource("Install on \(name)", bundle: .module)),
          action: .install(device.id))
      }
    }
    return entries
  }

  public static var toolbarToolTip: String { text("Send selected files to a device") }

  /// The name a device goes by in the menu and in notices: the one the Ferry menu shows,
  /// escaped, since the device supplies it.
  public static func displayName(of device: AttachedDevice) -> String {
    device.displayName
  }

  /// A ready device with a storage to write to.
  private static func canReceive(_ device: AttachedDevice) -> Bool {
    if case .ready(let storages) = device.state { !storages.isEmpty } else { false }
  }

  private static func text(_ key: String.LocalizationValue) -> String {
    String(localized: LocalizedStringResource(key, bundle: .module))
  }
}
