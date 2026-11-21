import DeviceKit
import Foundation

/// The words the extension gives FileProvider to show, from this target's String Catalog.
enum ProviderText {
  static func nameChanged(requested: String, actual: String) -> LocalizedStringResource {
    LocalizedStringResource("The device saved “\(requested)” as “\(actual)”.", bundle: .module)
  }

  static func unsupported(_ what: String) -> LocalizedStringResource {
    LocalizedStringResource("The device does not support \(what).", bundle: .module)
  }

  static func sizeMismatch(expected: UInt64, actual: UInt64) -> LocalizedStringResource {
    LocalizedStringResource(
      "The device stored \(actual) bytes where \(expected) were sent.", bundle: .module)
  }

  static func downloadSizeMismatch(listed: UInt64, received: UInt64) -> LocalizedStringResource {
    LocalizedStringResource(
      "The device sent \(received) bytes of a file it lists as \(listed) bytes.", bundle: .module)
  }

  static func folderTooDeep(_ name: String) -> LocalizedStringResource {
    LocalizedStringResource(
      "“\(name)” holds folders nested more than \(RemotePath.maxTreeDepth) deep, which Ferry does not delete.",
      bundle: .module)
  }

  static let readOnly = LocalizedStringResource(
    """
    Folders named like an app or a document package, and what they hold, can’t be changed from \
    this Mac. Change them on the device.
    """, bundle: .module)

  static let unexpectedResponse = LocalizedStringResource(
    "Ferry's helper sent an answer Ferry didn't expect. Quit and reopen Ferry, then try again.",
    bundle: .module)

  static let lostContact = LocalizedStringResource(
    "Ferry couldn't finish this. Try again; if it keeps failing, reconnect the device or reopen Ferry.",
    bundle: .module)

  static let package = LocalizedStringResource(
    "Packages and app bundles can’t be copied to the device. Compress it into a .zip first.",
    bundle: .module)

  static let packageName = LocalizedStringResource(
    """
    A folder on the device can’t take a package name, such as .app or .rtfd: macOS would open \
    it as an app or a document.
    """, bundle: .module)

  static let link = LocalizedStringResource(
    "Symbolic links and aliases can’t be copied to the device.", bundle: .module)

  /// Every string, with sample values, so a test can check each has its catalog entry.
  static let all: [LocalizedStringResource] = [
    nameChanged(requested: "a", actual: "b"), unsupported("copy"),
    sizeMismatch(expected: 2, actual: 1), downloadSizeMismatch(listed: 2, received: 1),
    folderTooDeep("Deep"), readOnly, unexpectedResponse, lostContact, package, packageName, link,
  ]
}
