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

  /// Whether a device reached this way offers the tools (installing apps among them): over ADB,
  /// by USB or the network.
  public static func offersTools(_ method: ConnectionMethod) -> Bool {
    DevicePresentation.toolMethods.contains(method)
  }

  /// A device-supplied name as the menu shows it: escaped, or "Unknown device" when empty.
  public static func deviceName(_ name: String) -> String {
    DevicePresentation.shownName(name)
  }

  /// Whether a file is offered to the agent as an app. The agent checks its contents.
  public static func isAPK(_ url: URL) -> Bool {
    DevicePresentation.isAPK(url)
  }
}
