import DeviceKit
import FerryIPC
import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ProviderBackend")

/// Everything the FileProvider extension does for one domain, forwarded to the agent.
///
/// Every argument is `Sendable`: the extension snapshots FileProvider's own arguments into
/// `ItemTemplate` and `ItemChanges` before it starts a task (see `ItemTemplate`). Items are named
/// by the agent's identifiers, so a rename or move keeps an item's identity.
///
/// FileProvider calls concurrently. The backend keeps no state between calls and adds no
/// ordering: the agent serializes operations per device. Calls carry no timeout of their own;
/// FileProvider times out and cancels its operations itself. A cancelled call sends no further
/// request and throws `CocoaError(.userCancelled)` as soon as the client returns; `AgentClient`
/// returns at once, leaving the agent to finish the request it already has.
///
/// File contents cross to the agent as open descriptors, never paths. Every error thrown is one
/// FileProvider understands: transport failures go through `ErrorMapping`, local file errors are
/// Cocoa errors.
public actor ProviderBackend {
  let domain: String
  private let client: any AgentSending

  public init(domain: String, client: any AgentSending) {
    self.domain = domain
    self.client = client
  }

  public func item(_ id: NSFileProviderItemIdentifier) async throws -> ProviderItem {
    ProviderItem(try await entry(.item(domain: domain, id: try Self.itemID(id))))
  }

  /// The items in a folder. The working set is not a folder: enumerate it with `workingSet(from:)`.
  public func children(of id: NSFileProviderItemIdentifier) async throws -> [ProviderItem] {
    let response = try await send(.list(domain: domain, folder: try Self.itemID(id)))
    guard case .entries(let entries) = response else { throw Self.unexpected(response) }
    return entries.map(ProviderItem.init)
  }

  /// Downloads into a new file in `dir`, and returns the item as the agent received it: its
  /// version describes exactly these bytes, including a size larger than the device's stale
  /// listing. Anything but an item removes the file, which may hold a truncated prefix.
  public func fetch(
    _ id: NSFileProviderItemIdentifier, into dir: URL, progress: TransferProgressHandler? = nil
  ) async throws -> (URL, ProviderItem) {
    let itemID = try Self.itemID(id)
    let url = dir.appending(path: UUID().uuidString, directoryHint: .notDirectory)
    let handle = try Self.createExclusively(url)
    do {
      defer { try? handle.close() }
      let item = ProviderItem(
        try await entry(.fetch(domain: domain, id: itemID), file: handle, progress: progress))
      return (url, item)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// Makes a folder or uploads `contents` as a file. Symbolic links and aliases have nothing
  /// MTP can store, and a package (a document or an app) is one item to FileProvider where the
  /// device would hold a folder, so they fail with `.cannotSynchronize`, which FileProvider
  /// takes as final until the item changes on the Mac, with a message saying why.
  public func create(
    _ template: ItemTemplate, contents: URL?, progress: TransferProgressHandler? = nil
  ) async throws -> ProviderItem {
    let request = AgentRequest.create(
      domain: domain, parent: template.parent, name: template.filename,
      isFolder: template.kind == .folder)
    switch template.kind {
    case .link:
      throw Self.linkRefused
    case .package:
      throw Self.packageRefused
    case .folder:
      return ProviderItem(try await entry(request))
    case .file:
      break
    }
    guard let contents else { throw CocoaError(.featureUnsupported) }
    let handle = try FileHandle(forReadingFrom: contents)
    defer { try? handle.close() }
    return ProviderItem(try await entry(request, file: handle, progress: progress))
  }

  /// For a create FileProvider marks `.mayAlreadyExist` (an import after its state was lost, or
  /// a merge): the device's item of that name in the parent, if it is the same item: a folder
  /// for a folder, or a file of the same size and modification time (to the second, all MTP
  /// keeps). `nil` when none matches; the caller then creates the item, or, with no contents to
  /// send, reports that it has none.
  public func existing(matching template: ItemTemplate) async throws -> ProviderItem? {
    let response = try await send(.list(domain: domain, folder: template.parent))
    guard case .entries(let entries) = response else { throw Self.unexpected(response) }
    let name = template.filename.precomposedStringWithCanonicalMapping
    guard let entry = entries.first(where: { $0.item.path.name == name }) else { return nil }
    switch (template.kind, entry.item.kind) {
    case (.folder, .folder), (.package, .folder):
      return ProviderItem(entry)
    case (.file, .file):
      guard let size = template.size, let modified = template.modified, size == entry.item.size,
        Self.seconds(modified) == Self.seconds(entry.item.modified)
      else { return nil }
      return ProviderItem(entry)
    default:
      return nil
    }
  }

  private static func seconds(_ date: Date) -> Int64 {
    Int64(clamping: Int(exactly: date.timeIntervalSince1970.rounded(.down)) ?? 0)
  }

  /// Applies the changed fields in order: parent (move), then filename (rename), then contents.
  /// New contents carry `base`, the version they were made from, and `onConflict` says what the
  /// agent does if the device's file has moved on from it.
  /// The item is read first when its parent or name may change, so a field reported as changed
  /// that names what the item already has sends nothing. The item keeps `id` throughout: a
  /// different identifier would tell FileProvider to merge the item into another.
  public func modify(
    _ id: NSFileProviderItemIdentifier, to template: ItemTemplate, changed: ItemChanges,
    contents: URL?, base: ContentVersion? = nil, onConflict: ConflictPolicy = .keepBoth,
    progress: TransferProgressHandler? = nil
  ) async throws -> ProviderItem {
    let itemID = try Self.itemID(id)
    var latest: ProviderEntry?

    if !changed.isDisjoint(with: [.parent, .filename]) {
      var current = try await entry(.item(domain: domain, id: itemID))
      if changed.contains(.parent), current.parent != template.parent {
        current = try await entry(.move(domain: domain, id: itemID, toFolder: template.parent))
      }
      if changed.contains(.filename), let parent = current.item.path.parent {
        let renamed = try Self.mapped { () throws(TransportError) in
          try parent.appending(template.filename)
        }
        // Compared as paths, so another normal form of the same name is no change, but a change
        // of case is: the agent lets an item take a name only its own name collides with.
        if renamed != current.item.path {
          current = try await entry(.rename(domain: domain, id: itemID, to: template.filename))
        }
      }
      latest = current
    }
    if changed.contains(.contents), let contents {
      let handle = try FileHandle(forReadingFrom: contents)
      defer { try? handle.close() }
      latest = try await entry(
        .replaceContents(domain: domain, id: itemID, base: base, onConflict: onConflict),
        file: handle, progress: progress)
    }
    if let latest { return ProviderItem(latest) }
    return ProviderItem(try await entry(.item(domain: domain, id: itemID)))
  }

  /// One page of the working set: every item the agent has reported in the domain, root
  /// excluded. The working-set enumerator pages through it in `enumerateItems`, from FileProvider's
  /// initial page until `next` is `nil`, and follows changes after that with `currentAnchor()` and
  /// `changes(since:)`. FileProvider re-enumerates it after an expired anchor, so it must hold
  /// every item FileProvider has, or FileProvider would take the missing ones as deleted.
  public func workingSet(from page: NSFileProviderPage) async throws -> ProviderPage {
    let response = try await send(.workingSet(domain: domain, page: try Self.cursor(of: page)))
    guard case .page(let entries, let next) = response else { throw Self.unexpected(response) }
    return ProviderPage(
      items: entries.map(ProviderItem.init), next: next.map(NSFileProviderPage.init(rawValue:)))
  }

  /// The anchor the working set's changes start from now.
  public func currentAnchor() async throws -> NSFileProviderSyncAnchor {
    try await changes(from: nil).anchor
  }

  /// What changed in the domain since `anchor`, for the working set's enumerator. Throws
  /// `.syncAnchorExpired` when the agent cannot answer from `anchor` (it restarted, or too much
  /// changed since), so FileProvider enumerates everything again.
  public func changes(since anchor: NSFileProviderSyncAnchor) async throws -> ProviderChanges {
    try await changes(from: anchor)
  }

  /// Deletes the item, as the extension's `deleteItem` asks: `base` is the version FileProvider
  /// last had, and a folder's contents go with it only if `recursive`. A file the device changed
  /// since `base` is refused with `.deletionRejected` carrying the device's item, which
  /// FileProvider puts back. An item already gone is deleted already.
  public func delete(
    _ id: NSFileProviderItemIdentifier, base: ContentVersion? = nil, recursive: Bool = false
  ) async throws {
    let itemID = try Self.itemID(id)
    let response = try await reply(
      .delete(domain: domain, id: itemID, base: base, recursive: recursive))
    switch response {
    // Already gone counts as deleted, as FileProvider expects.
    case .done, .failure(.unknownItem), .failure(.notFound):
      return
    case .failure(.changedOnDevice):
      guard let current = try? await item(id) else {
        throw NSFileProviderError(.deletionRejected)
      }
      throw NSError.fileProviderErrorForRejectedDeletion(of: current)
    case .failure(let error):
      throw ErrorMapping.fileProviderError(error)
    default:
      throw Self.unexpected(response)
    }
  }

  // MARK: Requests

  private func changes(from anchor: NSFileProviderSyncAnchor?) async throws -> ProviderChanges {
    let response = try await send(.changes(domain: domain, since: anchor?.rawValue))
    guard case .changes(let next, let updated, let deleted, let expired) = response else {
      throw Self.unexpected(response)
    }
    if expired { throw NSFileProviderError(.syncAnchorExpired) }
    return ProviderChanges(
      anchor: NSFileProviderSyncAnchor(rawValue: next), updated: updated.map(ProviderItem.init),
      deleted: deleted.map(NSFileProviderItemIdentifier.init))
  }

  func entry(
    _ request: AgentRequest, file: FileHandle? = nil, progress: TransferProgressHandler? = nil
  ) async throws -> ProviderEntry {
    let response = try await send(request, file: file, progress: progress)
    guard case .entry(let entry) = response else { throw Self.unexpected(response) }
    return entry
  }

  /// Sends `request`, turning a thrown error and a `.failure` reply alike into a FileProvider
  /// error.
  func send(
    _ request: AgentRequest, file: FileHandle? = nil, progress: TransferProgressHandler? = nil
  ) async throws -> AgentResponse {
    let response = try await reply(request, file: file, progress: progress)
    if case .failure(let error) = response {
      log.info(
        "\(String(describing: request), privacy: .private) refused: \(error, privacy: .private)")
      throw ErrorMapping.fileProviderError(error)
    }
    return response
  }

  /// Sends `request` and returns the agent's reply as it is, `.failure` included. Only a thrown
  /// error becomes a FileProvider error.
  private func reply(
    _ request: AgentRequest, file: FileHandle? = nil, progress: TransferProgressHandler? = nil
  ) async throws -> AgentResponse {
    if Task.isCancelled { throw CocoaError(.userCancelled) }
    do {
      return try await client.send(request, file: file, progress: progress)
    } catch {
      log.log(
        level: error.logType,
        "\(String(describing: request), privacy: .private) failed: \(error, privacy: .private)")
      throw ErrorMapping.fileProviderError(error)
    }
  }

  /// Packages, documents and apps alike: one item to FileProvider where the device would hold a
  /// folder. `.cannotSynchronize` is final until the item changes.
  static let packageRefused = NSFileProviderError(
    .cannotSynchronize,
    userInfo: [
      NSLocalizedDescriptionKey:
        "Packages and app bundles can’t be copied to the device. Compress it into a .zip first."
    ])

  static let linkRefused = NSFileProviderError(
    .cannotSynchronize,
    userInfo: [
      NSLocalizedDescriptionKey: "Symbolic links and aliases can’t be copied to the device."
    ])

  static func unexpected(_ response: AgentResponse) -> any Error {
    log.error("unexpected response from agent: \(String(describing: response), privacy: .private)")
    return ErrorMapping.fileProviderError(.io("Unexpected response from the Ferry agent."))
  }

  // MARK: Local mapping

  /// A page after the first carries the agent's cursor: the last identifier it served, as
  /// UTF-8. Anything from FileProvider other than an initial page or such a cursor is expired.
  private static func cursor(of page: NSFileProviderPage) throws -> Data? {
    let initial = [
      NSFileProviderPage.initialPageSortedByName as Data,
      NSFileProviderPage.initialPageSortedByDate as Data,
    ]
    if initial.contains(page.rawValue) { return nil }
    guard let text = String(data: page.rawValue, encoding: .utf8), ItemID(rawValue: text) != nil
    else { throw NSFileProviderError(.pageExpired) }
    return page.rawValue
  }

  /// The trash, the working set and anything else the agent did not assign name no item.
  private static func itemID(_ id: NSFileProviderItemIdentifier) throws -> ItemID {
    guard let itemID = ItemID(id) else { throw NSFileProviderError(.noSuchItem) }
    return itemID
  }

  private static func mapped<T>(_ body: () throws(TransportError) -> T) throws -> T {
    do {
      return try body()
    } catch {
      throw ErrorMapping.fileProviderError(error)
    }
  }

  /// Opens a new file for writing, failing if anything is already at `url`.
  private static func createExclusively(_ url: URL) throws -> FileHandle {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw ErrorMapping.forFileProvider(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }
}

/// Changes to a domain's items, for the working set's enumerator.
public struct ProviderChanges: Sendable {
  public let anchor: NSFileProviderSyncAnchor
  public let updated: [ProviderItem]
  public let deleted: [NSFileProviderItemIdentifier]
}

/// One page of the working set.
public struct ProviderPage: Sendable {
  public let items: [ProviderItem]
  /// `nil` on the last page.
  public let next: NSFileProviderPage?
}
