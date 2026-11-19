import Foundation

/// What may be sent from Finder: regular files only. The device holds a package as a folder,
/// and has no way to store a link, so those are refused with the words Finder's location uses
/// for them; a folder is copied through that location instead.
public enum LocalItem {
  public enum Refusal: Equatable, Sendable {
    case folder
    case package
    /// A symbolic link or a Finder alias.
    case link
    /// Anything else that is not a regular file: a device node, a socket.
    case notAFile

    public var message: String {
      switch self {
      case .folder:
        String(
          localized: LocalizedStringResource(
            """
            Folders can’t be sent from this menu. Copy the folder into the device’s location in \
            Finder, or compress it into a .zip first.
            """, bundle: .module))
      case .package:
        String(
          localized: LocalizedStringResource(
            """
            Packages and app bundles can’t be copied to the device. Compress it into a .zip \
            first.
            """, bundle: .module))
      case .link:
        String(
          localized: LocalizedStringResource(
            "Symbolic links and aliases can’t be copied to the device.", bundle: .module))
      case .notAFile:
        String(localized: LocalizedStringResource("Only files can be sent.", bundle: .module))
      }
    }
  }

  /// Why the item at `url` cannot be sent, or `nil` for a regular file. An item that cannot be
  /// inspected is left to the open that follows, which reports it.
  public static func refusal(for url: URL) -> Refusal? {
    let keys: Set<URLResourceKey> = [
      .isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
    // A link first: an alias is a regular file with contents.
    if values.isSymbolicLink == true || values.isAliasFile == true { return .link }
    if values.isDirectory == true { return values.isPackage == true ? .package : .folder }
    return values.isRegularFile == true ? nil : .notAFile
  }
}
