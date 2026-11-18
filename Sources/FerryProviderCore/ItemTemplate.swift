import FerryIPC
import FileProvider
import UniformTypeIdentifiers

/// What a new or changed item should look like, copied out of the `NSFileProviderItem`
/// FileProvider hands the extension.
///
/// `NSFileProviderItem` and FileProvider's request objects are not `Sendable`, so they must not
/// be captured by the task that does the work. The extension snapshots the item synchronously in
/// the callback with `ItemTemplate(_:)`, narrows the changed fields with `ItemChanges(_:)`, and
/// passes only those, identifiers and URLs to `ProviderBackend`. A snapshot that fails completes
/// the callback with its error at once:
///
/// ```swift
/// func createItem(basedOn item: NSFileProviderItem, ..., url: URL?, ...,
///                 completionHandler: @escaping (...) -> Void) -> Progress {
///   let template: ItemTemplate
///   do {
///     template = try ItemTemplate(item)
///   } catch {
///     completionHandler(nil, [], false, error)
///     return Progress()
///   }
///   Task {
///     do {
///       completionHandler(try await backend.create(template, contents: url), [], false, nil)
///     } catch {
///       completionHandler(nil, [], false, error)
///     }
///   }
///   return Progress()
/// }
/// ```
public struct ItemTemplate: Sendable, Equatable {
  /// What an item is on the Mac, and so what it becomes on the device.
  public enum Kind: Sendable, Equatable {
    case file
    case folder
    /// A package: a document (an `.rtfd`, a Keynote file) or an app or other code bundle. One
    /// item to FileProvider where the device would hold a folder, so Ferry does not copy it.
    case package
    /// A symbolic link or a Finder alias, which MTP has no way to store.
    case link
  }

  public let parent: ItemID
  public let filename: String
  public let kind: Kind
  /// The file's size and modification date on the Mac, when FileProvider gives them: what tells
  /// a file being imported again from the device's own copy.
  public let size: UInt64?
  public let modified: Date?

  public init(
    parent: ItemID, filename: String, kind: Kind, size: UInt64? = nil, modified: Date? = nil
  ) {
    self.parent = parent
    self.filename = filename
    self.kind = kind
    self.size = size
    self.modified = modified
  }

  /// Throws `.noSuchItem` when the parent is not a Ferry item, such as the trash.
  public init(_ item: any NSFileProviderItem) throws {
    guard let parent = ItemID(item.parentItemIdentifier) else {
      throw NSFileProviderError(.noSuchItem)
    }
    self.init(
      parent: parent, filename: item.filename, kind: Self.kind(of: item),
      size: (item.documentSize ?? nil).map(\.uint64Value),
      modified: item.contentModificationDate ?? nil)
  }

  /// A link is checked first: an alias is a file with contents.
  private static func kind(of item: any NSFileProviderItem) -> Kind {
    let type = item.contentType ?? .data
    let isLink = type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile)
    if isLink || (item.symlinkTargetPath ?? nil) != nil { return .link }
    guard type.conforms(to: .directory) else { return .file }
    // By type, or by name: a package copied with `cp -R` first arrives as a plain folder.
    return isPackage(type) || isPackage(named: item.filename) ? .package : .folder
  }

  /// A package or a bundle: a framework is a bundle Finder shows as a folder, but it is code.
  private static func isPackage(_ type: UTType) -> Bool {
    type.conforms(to: .package) || type.conforms(to: .bundle)
  }

  /// Whether a folder of this name is a package: its extension is a declared package type.
  private static func isPackage(named name: String) -> Bool {
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else {
      return false
    }
    return type.isDeclared && isPackage(type)
  }
}

/// The changed fields of an item that reach an MTP device: `NSFileProviderItemFields` narrowed
/// to parent, name and contents. Other fields, such as dates and tags, have nowhere to go.
public struct ItemChanges: OptionSet, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let parent = ItemChanges(rawValue: 1 << 0)
  public static let filename = ItemChanges(rawValue: 1 << 1)
  public static let contents = ItemChanges(rawValue: 1 << 2)

  public init(_ fields: NSFileProviderItemFields) {
    self = []
    if fields.contains(.parentItemIdentifier) { insert(.parent) }
    if fields.contains(.filename) { insert(.filename) }
    if fields.contains(.contents) { insert(.contents) }
  }
}

extension ItemID {
  /// The identifier FileProvider uses for an item, or `nil` for one that is not Ferry's: the
  /// trash, the working set, or anything the agent did not assign.
  public init?(_ identifier: NSFileProviderItemIdentifier) {
    if identifier == .rootContainer {
      self = .root
      return
    }
    // The root is only ever `.rootContainer`; its raw value is not an item.
    guard let id = ItemID(rawValue: identifier.rawValue), id != .root else { return nil }
    self = id
  }
}

extension NSFileProviderItemIdentifier {
  public init(_ id: ItemID) {
    self = id == .root ? .rootContainer : NSFileProviderItemIdentifier(id.rawValue)
  }
}
