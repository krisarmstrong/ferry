import CryptoKit
import DeviceKit
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// A device item as FileProvider sees it. Its identifier is its path, so a rename or move gives
/// it a new identity; the root is `.rootContainer`.
public final class ProviderItem: NSObject, NSFileProviderItem, Sendable {
  public let remote: RemoteItem

  public init(_ remote: RemoteItem) {
    self.remote = remote
  }

  public var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(remote.path) }

  /// The root's parent is the root, as FileProvider expects.
  public var parentItemIdentifier: NSFileProviderItemIdentifier {
    Self.identifier(remote.path.parent ?? .root)
  }

  /// Empty for the root, whose name FileProvider takes from the domain.
  public var filename: String { remote.path.name ?? "" }

  public var contentType: UTType {
    switch remote.kind {
    case .folder:
      return .folder
    case .file:
      let ext = (filename as NSString).pathExtension
      guard !ext.isEmpty else { return .data }
      return UTType(filenameExtension: ext, conformingTo: .data) ?? .data
    }
  }

  public var documentSize: NSNumber? {
    remote.kind == .file ? NSNumber(value: remote.size) : nil
  }

  public var contentModificationDate: Date? { remote.modified }

  /// On a folder, `.allowsReading` and `.allowsWriting` are `.allowsContentEnumerating` and
  /// `.allowsAddingSubItems`: the SDK defines them as the same bits.
  public var capabilities: NSFileProviderItemCapabilities {
    var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting]
    if remote.path != .root {
      capabilities.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting])
    }
    return capabilities
  }

  /// MTP has no content hash, so contents are versioned by size and modification date; metadata
  /// by path, which holds the name and the parent. Both are fixed bytes, stable across launches.
  public var itemVersion: NSFileProviderItemVersion {
    var content = Data()
    withUnsafeBytes(of: remote.size.bigEndian) { content.append(contentsOf: $0) }
    withUnsafeBytes(of: remote.modified.timeIntervalSince1970.bitPattern.bigEndian) {
      content.append(contentsOf: $0)
    }
    let metadata = Data(SHA256.hash(data: Data(remote.path.description.utf8)))
    return NSFileProviderItemVersion(contentVersion: content, metadataVersion: metadata)
  }

  static func identifier(_ path: RemotePath) -> NSFileProviderItemIdentifier {
    path == .root ? .rootContainer : NSFileProviderItemIdentifier(path.description)
  }
}
