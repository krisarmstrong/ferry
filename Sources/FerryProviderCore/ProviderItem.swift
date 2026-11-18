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
      // Whatever its name (`Notes.rtfd`, `Ferry.app`): Ferry does not copy packages, so Finder
      // lists what a device folder holds and never offers code from a USB device to launch.
      return .folder
    case .file:
      let ext = (filename as NSString).pathExtension
      guard !ext.isEmpty else { return .data }
      return UTType(filenameExtension: ext, conformingTo: .data) ?? .data
    }
  }

  public var documentSize: NSNumber? {
    entry.item.kind == .file ? NSNumber(value: entry.item.size) : nil
  }

  public var contentModificationDate: Date? { entry.item.modified }

  /// Every file from the device, and every folder macOS takes for a package by its name (see
  /// `isPackageNamed`), carries `com.apple.quarantine` as a downloaded file does, so
  /// Gatekeeper checks an app or script from a USB device before it first runs. FileProvider
  /// writes an item's syncable extended attributes onto the file on disk; the extension's
  /// Info.plist declares this one syncable. A marker set on the fetched file itself does not
  /// reach the disk: FileProvider takes only its contents.
  public var extendedAttributes: [String: Data] {
    guard entry.item.kind == .file || isPackageNamed else { return [:] }
    return [Self.quarantineAttribute: quarantine]
  }

  /// A folder whose name's extension is a package type (`Ferry.app`, `Notes.rtfd`). Ferry
  /// presents it as a plain folder, but macOS types a folder on disk by its extension, so Finder
  /// still shows it as a document or an app; the quarantine makes Gatekeeper check such an app
  /// as a download.
  private var isPackageNamed: Bool {
    let ext = (filename as NSString).pathExtension
    guard entry.item.kind == .folder, !ext.isEmpty,
      let type = UTType(filenameExtension: ext, conformingTo: .directory)
    else { return false }
    return type.isDeclared && type.conforms(to: .package)
  }

  static let quarantineAttribute = "com.apple.quarantine"

  /// `0083;<seconds since 1970, hex>;Ferry;<identifier>`: downloaded (0x0003) from an untrusted
  /// source (0x0080) by Ferry. Built from the item alone, so it is the same every time.
  private var quarantine: Data {
    let seconds = max(0, Int(entry.item.modified.timeIntervalSince1970.rounded(.down)))
    return Data("0083;\(String(seconds, radix: 16));Ferry;\(entry.id.rawValue)".utf8)
  }

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
  /// Bumped when Ferry changes what an item's metadata holds (2: the quarantine attribute on
  /// files; 3: on packages too; 4: every folder a plain folder, none quarantined; 5: folders
  /// named like packages quarantined), so items FileProvider already knows pick it up.
  static let metadataRevision = 5

  public var itemVersion: NSFileProviderItemVersion {
    let content = ContentVersion(entry.item).encoded
    // Neither an identifier nor a name contains "/", so the fields cannot run together.
    let metadata = Data(
      SHA256.hash(
        data: Data(
          "\(entry.parent.rawValue)/\(filename)/\(capabilities.rawValue)/\(Self.metadataRevision)"
            .utf8)))
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
