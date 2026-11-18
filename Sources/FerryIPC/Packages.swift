import DeviceKit
import Foundation
import UniformTypeIdentifiers

/// Document packages (an `.rtfd`, a Keynote file): folders that FileProvider, like Finder,
/// treats as one item. Ferry keeps them opaque the same way: a package's inner files are never
/// separate items, and it is fetched, created and replaced whole.
///
/// A folder named like code (an app, a plug-in, any other bundle) is not one: it stays an
/// ordinary folder, so Finder never offers code from a USB device as something to launch.
public enum Packages {
  /// The document package type a folder of this name is, if any.
  public static func documentType(named name: String) -> UTType? {
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .package),
      type.isDeclared
    else { return nil }
    return isDocumentPackage(type) ? type : nil
  }

  /// Whether `type` is a package that holds a document rather than code.
  public static func isDocumentPackage(_ type: UTType) -> Bool {
    type.conforms(to: .package) && !isCode(type)
  }

  /// Whether `type` is an app, a bundle, a plug-in, a framework, an extension or anything else
  /// that runs.
  public static func isCode(_ type: UTType) -> Bool {
    codeTypes.contains(where: type.conforms(to:))
  }

  /// Whether `path` is a document package or lies inside one.
  public static func isPackageOrInside(_ path: RemotePath) -> Bool {
    var current = RemotePath.root
    for component in path.components {
      guard let next = try? current.appending(component) else { return false }
      if documentType(named: component) != nil { return true }
      current = next
    }
    return false
  }

  /// Whether `path` lies inside a document package (the package itself excluded).
  public static func isInsidePackage(_ path: RemotePath) -> Bool {
    guard let parent = path.parent else { return false }
    return isPackageOrInside(parent)
  }

  /// Bundles of code, and anything that runs.
  private static let codeTypes: [UTType] = [
    .application, .applicationBundle, .bundle, .executable, .pluginBundle, .framework,
    .applicationExtension, .script, UTType("com.apple.system-extension"),
  ].compactMap { $0 }
}
