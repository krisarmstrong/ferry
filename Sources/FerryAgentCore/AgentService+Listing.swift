import DeviceKit
import FerryIPC
import Foundation

/// Listing a folder, a page at a time, and the working set.
extension AgentService {
  /// One page of the folder: a fresh listing of the device for the first, the rest of that
  /// listing for each later one.
  func list(_ folder: ItemID, in domain: String, page: Data?) async throws(TransportError)
    -> AgentResponse
  {
    let folder = FolderPages.Folder(domain: domain, id: folder)
    let (entries, next) =
      if let page {
        try folderPages.page(page, of: folder)
      } else {
        folderPages.first(of: try await listing(folder.id, in: domain), in: folder)
      }
    return .page(entries: entries, next: next)
  }

  private func listing(_ folder: ItemID, in domain: String) async throws(TransportError)
    -> [ProviderEntry]
  {
    let (path, entries) = try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: folder)
      let items = try await route.writer.visibleList(path, in: route.storage)
      return (path, await route.items.listed(path, children: items))
    }
    // Outside the gate: the watch reads the domain's table.
    await changes?.listed(path, in: domain)
    return entries
  }

  /// One page of the working set. The page token is the last identifier served, as UTF-8.
  func workingSet(_ page: Data?, in domain: String) async throws(TransportError)
    -> AgentResponse
  {
    let cursor = try page.map { data throws(TransportError) in
      guard let id = String(data: data, encoding: .utf8).flatMap(ItemID.init(rawValue:)) else {
        throw .io(String(localized: AgentText.badRequest))
      }
      return id
    }
    let (entries, next) = try await gated(domain) { route in
      await route.items.workingSet(after: cursor, size: Self.workingSetPageSize)
    }
    return .page(entries: entries, next: next.map { Data($0.rawValue.utf8) })
  }
}
