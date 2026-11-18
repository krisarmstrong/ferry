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

  public var contentType: UTType {
    switch entry.item.kind {
    case .folder:
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

  /// On a folder, `.allowsReading` and `.allowsWriting` are `.allowsContentEnumerating` and
  /// `.allowsAddingSubItems`: the SDK defines them as the same bits.
  public var capabilities: NSFileProviderItemCapabilities {
    var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting]
    if entry.id != .root {
      capabilities.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting])
    }
    return capabilities
  }

  /// MTP has no content hash, so contents are versioned by size and modification date; metadata
  /// by the parent's identifier and the name. Both are fixed bytes, stable across launches.
  public var itemVersion: NSFileProviderItemVersion {
    let item = entry.item
    var content = Data()
    withUnsafeBytes(of: item.size.bigEndian) { content.append(contentsOf: $0) }
    withUnsafeBytes(of: item.modified.timeIntervalSince1970.bitPattern.bigEndian) {
      content.append(contentsOf: $0)
    }
    // Neither an identifier nor a name contains "/", so the two cannot run together.
    let metadata = Data(SHA256.hash(data: Data("\(entry.parent.rawValue)/\(filename)".utf8)))
    return NSFileProviderItemVersion(contentVersion: content, metadataVersion: metadata)
  }
}
