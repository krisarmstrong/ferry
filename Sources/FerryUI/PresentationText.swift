import DeviceKit
import FerryIPC
import Foundation

/// The menu's rules and wording that the Finder Sync extension shares, so a device offers the
/// same tools and a failure reads the same in Finder as in the menu.
public enum PresentationText {
  public static func message(for error: TransportError) -> String {
    DevicePresentation.message(for: error)
  }

  public static func message(for failure: ToolFailure) -> String {
    DevicePresentation.message(for: failure)
  }

  /// Whether the device is served over ADB, by USB or the network, so it can install apps.
  public static func offersTools(_ device: AttachedDevice) -> Bool {
    DevicePresentation.offersTools(device)
  }

  /// Whether a file is offered to the agent as an app. The agent checks its contents.
  public static func isAPK(_ url: URL) -> Bool {
    DevicePresentation.isAPK(url)
  }
}
