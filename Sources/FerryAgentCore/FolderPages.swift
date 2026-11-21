import DeviceKit
import FerryIPC
import Foundation

/// Folder listings served a page at a time (audit M9), so a 20,000-item folder reaches Finder in
/// replies of `pageSize` entries and Finder fills it as they arrive.
///
/// The device is listed once, on the first page; the rest of that listing waits here under a
/// random token until its last page is served. Only the `limit` most recent listings wait: an
/// older token, or one from before an agent restart, is `.pageExpired`, which makes FileProvider
/// list the folder again from its first page. The last page served drops the listing, so asking
/// for it again is `.pageExpired` too.
///
/// Later pages come from the listing taken for the first, not from the device: an item deleted
/// or moved meanwhile is still served with its old identifier, and FileProvider applies the
/// change from the working set's next pass.
struct FolderPages {
  static let pageSize = 1_000
  static let limit = 16

  private struct Pending {
    let token: UUID
    let folder: Folder
    let entries: [ProviderEntry]
  }

  /// The folder a listing is of: a token serves only further pages of the same folder.
  struct Folder: Equatable {
    let domain: String
    let id: ItemID
  }

  /// Oldest first.
  private var pending: [Pending] = []

  /// The first page of a new listing, and the token for the next page if there is one.
  mutating func first(of entries: [ProviderEntry], in folder: Folder) -> (
    entries: [ProviderEntry], next: Data?
  ) {
    guard entries.count > Self.pageSize else { return (entries, nil) }
    let token = UUID()
    pending.append(Pending(token: token, folder: folder, entries: entries))
    pending.removeFirst(max(0, pending.count - Self.limit))
    return (Array(entries.prefix(Self.pageSize)), Self.data(token, Self.pageSize))
  }

  /// The page a token from `first` or from this names. A token names a position, so a page asked
  /// for again is the same page.
  mutating func page(_ page: Data, of folder: Folder) throws(TransportError) -> (
    entries: [ProviderEntry], next: Data?
  ) {
    let parts = String(bytes: page, encoding: .utf8)?.split(separator: " ") ?? []
    guard parts.count == 2, let token = UUID(uuidString: String(parts[0])),
      let offset = Int(parts[1]), offset > 0,
      let index = pending.firstIndex(where: { $0.token == token && $0.folder == folder }),
      offset < pending[index].entries.count
    else { throw .pageExpired }
    let all = pending[index].entries
    let end = min(offset + Self.pageSize, all.count)
    guard end < all.count else {
      pending.remove(at: index)
      return (Array(all[offset..<end]), nil)
    }
    return (Array(all[offset..<end]), Self.data(token, end))
  }

  private static func data(_ token: UUID, _ offset: Int) -> Data {
    Data("\(token.uuidString) \(offset)".utf8)
  }
}
