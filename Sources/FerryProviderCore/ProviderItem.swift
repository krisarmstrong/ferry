import CryptoKit
import DeviceKit
import FerryIPC
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// A device item as FileProvider sees it. Its identifier is the agent's `ItemID`, which a rename
/// or move keeps; the root is `.rootContainer`.
public final class ProviderItem: NSObject, NSFileProviderItem, Sendable {
  public let entry: ProviderEntry

  public init(_ entry: ProviderEntry) {
    self.entry = entry
  }

  public var itemIdentifier: NSFileProviderItemIdentifier { .init(entry.id) }

  /// The root's parent is the root, as FileProvider expects.
  public var parentItemIdentifier: NSFileProviderItemIdentifier { .init(entry.parent) }

  /// Never empty: FileProvider aborts the extension on an item without a name. Only the root's
  /// path has no last component, and Finder shows the domain's display name for the root, so its
  /// fixed name is never seen.
  public var filename: String { entry.item.path.name ?? Self.rootFilename }

  static let rootFilename = "Device"

  /// `.allowsEvicting`, which the SDK marks deprecated in favour of `contentPolicy`. macOS 27
  /// still requires it: without it, eviction fails with `NSFileProviderError.nonEvictable`
  /// (-2008, "the item has not been assigned the evictable capability") even under the default
  /// lazy content policy. Spelled by value so the deprecation does not warn on every build.
  public static let allowsEvicting = NSFileProviderItemCapabilities(rawValue: 1 << 6)

  public var contentType: UTType {
    switch entry.item.kind {
    case .folder:
      // A folder named like a document package (`Notes.rtfd`) is one, as on a Mac volume. A
      // folder named like code (an app, plug-in or any other bundle) stays a folder, so Finder
      // never offers code from a USB device as something to launch.
      let ext = (filename as NSString).pathExtension
      guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .package),
        type.isDeclared, !Self.codeTypes.contains(where: type.conforms(to:))
      else { return .folder }
      return type
    case .file:
      let ext = (filename as NSString).pathExtension
      guard !ext.isEmpty else { return .data }
      return UTType(filenameExtension: ext, conformingTo: .data) ?? .data
    }
  }

  /// Bundles of code, and anything that runs.
  private static let codeTypes: [UTType] = [
    .application, .applicationBundle, .bundle, .executable, .pluginBundle, .framework,
    .applicationExtension, .script, UTType("com.apple.system-extension"),
  ].compactMap { $0 }

  public var documentSize: NSNumber? {
    entry.item.kind == .file ? NSNumber(value: entry.item.size) : nil
  }

  public var contentModificationDate: Date? { entry.item.modified }

  /// On a folder, `.allowsReading` and `.allowsWriting` are `.allowsContentEnumerating` and
  /// `.allowsAddingSubItems`: the SDK defines them as the same bits.
  ///
  /// Every item is evictable, so Finder offers Remove Download and the system can reclaim space:
  /// the device keeps the contents.
  public var capabilities: NSFileProviderItemCapabilities {
    var capabilities: NSFileProviderItemCapabilities = [
      .allowsReading, .allowsWriting, Self.allowsEvicting,
    ]
    if entry.id != .root {
      capabilities.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting])
    }
    return capabilities
  }

  /// MTP has no content hash, so contents are versioned by size and modification date; metadata
  /// by the parent's identifier, the name and the capabilities. Both are fixed bytes, stable
  /// across launches. FileProvider keeps an item's metadata until its version changes, so a
  /// Ferry that changes capabilities must change the version too, or items already known keep
  /// the old ones.
  public var itemVersion: NSFileProviderItemVersion {
    let content = ContentVersion(entry.item).encoded
    // Neither an identifier nor a name contains "/", so the fields cannot run together.
    let metadata = Data(
      SHA256.hash(
        data: Data("\(entry.parent.rawValue)/\(filename)/\(capabilities.rawValue)".utf8)))
    return NSFileProviderItemVersion(contentVersion: content, metadataVersion: metadata)
  }
}

extension ContentVersion {
  /// The base of a change FileProvider sends, or `nil` when there is none to check against:
  /// FileProvider has never seen the item in sync (`beforeFirstSyncComponent`), or the version is
  /// not one Ferry made.
  public init?(base version: NSFileProviderItemVersion) {
    guard version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent else {
      return nil
    }
    self.init(encoded: version.contentVersion)
  }
}
