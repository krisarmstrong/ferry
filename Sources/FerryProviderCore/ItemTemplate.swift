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
  public let parent: ItemID
  public let filename: String
  public let isFolder: Bool

  public init(parent: ItemID, filename: String, isFolder: Bool) {
    self.parent = parent
    self.filename = filename
    self.isFolder = isFolder
  }

  /// Throws `.noSuchItem` when the parent is not a Ferry item, such as the trash.
  public init(_ item: any NSFileProviderItem) throws {
    guard let parent = ItemID(item.parentItemIdentifier) else {
      throw NSFileProviderError(.noSuchItem)
    }
    self.init(
      parent: parent, filename: item.filename,
      isFolder: item.contentType?.conforms(to: .folder) == true)
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
