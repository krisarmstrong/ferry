import FerryIPC
import FileProvider
import Foundation

/// Folder listings, which the agent serves a page at a time.
extension ProviderBackend {
  /// One page of a folder's items, from FileProvider's initial page until `next` is `nil`. The
  /// working set is not a folder: enumerate it with `workingSet(from:)`. An expired page is
  /// `NSFileProviderError(.pageExpired)`, after which FileProvider lists the folder again.
  public func children(of id: NSFileProviderItemIdentifier, from page: NSFileProviderPage)
    async throws -> ProviderPage
  {
    let entries = try await listing(try Self.itemID(id), page: Self.listingPage(page))
    return ProviderPage(
      items: entries.entries.map(ProviderItem.init),
      next: entries.next.map(NSFileProviderPage.init(rawValue:)))
  }

  /// Every item in a folder, every page of it.
  public func children(of id: NSFileProviderItemIdentifier) async throws -> [ProviderItem] {
    try await allEntries(in: try Self.itemID(id)).map(ProviderItem.init)
  }

  func allEntries(in folder: ItemID) async throws -> [ProviderEntry] {
    var all: [ProviderEntry] = []
    var page: Data?
    repeat {
      let listing = try await listing(folder, page: page)
      all += listing.entries
      page = listing.next
    } while page != nil
    return all
  }

  private func listing(_ folder: ItemID, page: Data?) async throws -> (
    entries: [ProviderEntry], next: Data?
  ) {
    let response = try await send(.list(domain: domain, folder: folder, page: page))
    guard case .page(let entries, let next) = response else { throw Self.unexpected(response) }
    return (entries, next)
  }

  /// FileProvider's first page (either of its initial pages) is a fresh listing.
  private static func listingPage(_ page: NSFileProviderPage) -> Data? {
    isInitial(page) ? nil : page.rawValue
  }

  static func isInitial(_ page: NSFileProviderPage) -> Bool {
    [
      NSFileProviderPage.initialPageSortedByName as Data,
      NSFileProviderPage.initialPageSortedByDate as Data,
    ].contains(page.rawValue)
  }
}
