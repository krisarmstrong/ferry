import DeviceKit
import Foundation

/// An item's identity in a domain, assigned by the agent the first time it sees the item and kept
/// across renames and moves.
///
/// FileProvider may write identifiers to system logs, so they never carry a name: every
/// identifier is a random UUID string, except `root`. Decoding accepts nothing else.
public struct ItemID: Hashable, Sendable, Codable, RawRepresentable {
  /// The storage root, which FileProvider calls `.rootContainer`.
  public static let root = ItemID(uncheckedRawValue: "root")

  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue == Self.root.rawValue || UUID(uuidString: rawValue)?.uuidString == rawValue
    else { return nil }
    self.rawValue = rawValue
  }

  private init(uncheckedRawValue: String) {
    rawValue = uncheckedRawValue
  }

  /// A new identifier, never equal to one assigned before.
  public static func random() -> ItemID {
    ItemID(uncheckedRawValue: UUID().uuidString)
  }

  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard let id = ItemID(rawValue: string) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid item identifier"))
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// An item with its identity, as the agent reports it. The root is its own parent.
public struct ProviderEntry: Sendable, Codable, Equatable {
  public let id: ItemID
  public let parent: ItemID
  public let item: RemoteItem

  public init(id: ItemID, parent: ItemID, item: RemoteItem) {
    self.id = id
    self.parent = parent
    self.item = item
  }
}

/// A file's contents version: its size and modification date as the device reports them, since
/// MTP has no content hash. FileProvider holds it as the item's content version (see
/// `encoded`), and sends it back as the base of a change, so the agent can tell whether the
/// device's file is still the one the change was made to.
public struct ContentVersion: Codable, Sendable, Hashable {
  public let size: UInt64
  /// The bit pattern of the modification date's seconds since 1970, so the version survives
  /// every encoding exactly.
  public let modifiedBits: UInt64

  public init(_ item: RemoteItem) {
    size = item.size
    modifiedBits = item.modified.timeIntervalSince1970.bitPattern
  }

  /// Reads `encoded`; anything else, such as FileProvider's before-first-sync marker, is `nil`.
  public init?(encoded: Data) {
    guard encoded.count == 16 else { return nil }
    let bytes = [UInt8](encoded)
    func word(_ offset: Int) -> UInt64 {
      bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
    size = word(0)
    modifiedBits = word(8)
  }

  /// Sixteen bytes: the size, then the date's bits, both big-endian.
  public var encoded: Data {
    var data = Data()
    withUnsafeBytes(of: size.bigEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: modifiedBits.bigEndian) { data.append(contentsOf: $0) }
    return data
  }
}

/// What the agent does when a file's contents are replaced from a version the device no longer
/// has.
public enum ConflictPolicy: String, Codable, Sendable {
  /// Keeps the device's file and uploads the Mac's contents beside it as a conflict copy.
  case keepBoth
  /// Refuses with `.changedOnDevice`, for FileProvider to merge and try again.
  case fail
}

/// A request from the app or the FileProvider extension to the agent, sent as JSON.
///
/// It arrives from a sandboxed process the agent does not control. Items are named by `ItemID`,
/// which the agent resolves through its own table, so a client can only reach items the agent
/// has reported. File contents never travel as paths: `fetch`, `create` (of a file) and
/// `replaceContents` come with an open file descriptor, so the agent never opens a file the peer
/// named.
public enum AgentRequest: Codable, Sendable, Equatable {
  /// Answered with `.status(devices:providerEnabled:)`.
  case status
  case recheck(DeviceID)
  /// Lists again every folder the agent knows on the device's domains, so changes made on the
  /// device reach Finder.
  case refresh(DeviceID)
  case eject(DeviceID)
  case removeAllDomains
  case item(domain: String, id: ItemID)
  case list(domain: String, folder: ItemID)
  /// Downloads the file into the writable file sent with the request.
  case fetch(domain: String, id: ItemID)
  /// Uploads the readable file sent with the request as `name` in `parent`, or makes a folder
  /// (sent with no file). `name` must be one path component.
  case create(domain: String, parent: ItemID, name: String, isFolder: Bool)
  case rename(domain: String, id: ItemID, to: String)
  case move(domain: String, id: ItemID, toFolder: ItemID)
  /// Replaces the file with the readable file sent with the request. `base` is the version the
  /// new contents were made from, if known; if the device's file is no longer at it,
  /// `onConflict` decides.
  case replaceContents(
    domain: String, id: ItemID, base: ContentVersion?, onConflict: ConflictPolicy)
  /// Deletes the item. A file the device changed since `base` is `.changedOnDevice`; a folder
  /// that holds anything is `.directoryNotEmpty` unless `recursive`.
  case delete(domain: String, id: ItemID, base: ContentVersion?, recursive: Bool)
  /// The changes to the domain's items since `since`, an anchor from an earlier `.changes`
  /// response; `nil` asks only for the current anchor. Feeds FileProvider's working set.
  case changes(domain: String, since: Data?)
  /// One page of every item the agent has reported in the domain, root excluded, in a stable
  /// order: the working set FileProvider enumerates after it drops its cache. `page` is the
  /// opaque `next` of the previous `.page`, or `nil` for the first.
  case workingSet(domain: String, page: Data?)
}

public enum AgentResponse: Codable, Sendable, Equatable {
  case status(devices: [AttachedDevice], providerEnabled: Bool)
  case entry(ProviderEntry)
  case entries([ProviderEntry])
  /// Answers `.changes`: each changed item's latest state, the items gone, and the anchor to ask
  /// from next. `expired` means `since` cannot be answered (it predates the agent process or the
  /// agent's window), so the lists are empty and the client must enumerate everything again.
  case changes(anchor: Data, updated: [ProviderEntry], deleted: [ItemID], expired: Bool)
  /// Answers `.workingSet`. `next` is `nil` on the last page.
  case page(entries: [ProviderEntry], next: Data?)
  /// Answers `.eject` and `.removeAllDomains`: where the system saved changes the removed
  /// domains had not sent to the device yet, if any.
  case removed(preserved: [URL])
  case done
  case failure(TransportError)
}
