import Foundation
import UniformTypeIdentifiers

// MARK: Package names

extension RemotePath {
  /// Whether a folder of this name is a package to macOS: its extension is a declared type
  /// conforming to `com.apple.package` (`Ferry.app`, `Notes.rtfd`). macOS opens such a folder as
  /// an app or a document whatever Ferry presents, so it is read-only from the Mac.
  public static func isPackageName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory)
    else { return false }
    return type.isDeclared && type.conforms(to: .package)
  }

  /// Whether this path is a package-named folder (`isFolder`) or lies inside one.
  public func isInPackageFolder(isFolder: Bool) -> Bool {
    let folders = isFolder ? components : Array(components.dropLast())
    return folders.contains(where: Self.isPackageName)
  }
}
