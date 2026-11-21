import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

struct FolderPagesTests {
  private let folder = FolderPages.Folder(domain: "SER0000AAAA|Internal|vol0", id: .root)

  private func entries(_ count: Int) throws -> [ProviderEntry] {
    try (0..<count).map {
      ProviderEntry(
        id: .random(), parent: .root,
        item: RemoteItem(
          path: try path("/f\($0)"), kind: .file, size: 1, modified: Date(timeIntervalSince1970: 0))
      )
    }
  }

  @Test func aSmallListingIsOnePage() throws {
    var pages = FolderPages()
    let all = try entries(FolderPages.pageSize)
    let first = pages.first(of: all, in: folder)
    #expect(first.entries == all)
    #expect(first.next == nil)
  }

  @Test func aLargeListingComesInPagesInOrder() throws {
    var pages = FolderPages()
    let all = try entries(FolderPages.pageSize * 2 + 5)
    let first = pages.first(of: all, in: folder)
    let token = try #require(first.next)
    let second = try pages.page(token, of: folder)
    // A page asked for again is the same page: the token names a position.
    #expect(try pages.page(token, of: folder) == second)
    let third = try pages.page(try #require(second.next), of: folder)
    #expect(third.next == nil)
    #expect(first.entries + second.entries + third.entries == all)
    #expect(first.entries.count == FolderPages.pageSize)
    // The last page served, the listing is gone.
    #expect(throws: TransportError.pageExpired) { try pages.page(token, of: folder) }
  }

  @Test func aTokenServesOnlyItsFolder() throws {
    var pages = FolderPages()
    let token = try #require(
      pages.first(of: try entries(FolderPages.pageSize + 1), in: folder).next)
    let other = FolderPages.Folder(domain: folder.domain, id: .random())
    #expect(throws: TransportError.pageExpired) { try pages.page(token, of: other) }
    #expect(throws: TransportError.pageExpired) { try pages.page(Data("junk".utf8), of: folder) }
  }

  @Test func onlyTheMostRecentListingsWait() throws {
    var pages = FolderPages()
    let all = try entries(FolderPages.pageSize + 1)
    let oldest = try #require(pages.first(of: all, in: folder).next)
    for _ in 0..<FolderPages.limit { _ = pages.first(of: all, in: folder) }
    #expect(throws: TransportError.pageExpired) { try pages.page(oldest, of: folder) }
  }
}
