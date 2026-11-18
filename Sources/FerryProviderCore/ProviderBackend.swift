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
/// FileProvider times out and cancels its operations itself.
///
/// File contents cross to the agent as open descriptors, never paths. Every error thrown is one
/// FileProvider understands: transport failures go through `ErrorMapping`, local file errors are
/// Cocoa errors.
public actor ProviderBackend {
  private let domain: String
  private let client: any AgentSending

  public init(domain: String, client: any AgentSending) {
    self.domain = domain
    self.client = client
  }

  public func item(_ id: NSFileProviderItemIdentifier) async throws -> ProviderItem {
    ProviderItem(try await entry(.item(domain: domain, id: try Self.itemID(id))))
  }

  /// The working set enumerates no items of its own: it is fed by `changes(since:)`, which
  /// reports every item the agent has seen change.
  public func children(of id: NSFileProviderItemIdentifier) async throws -> [ProviderItem] {
    if id == .workingSet { return [] }
    let response = try await send(.list(domain: domain, folder: try Self.itemID(id)))
    guard case .entries(let entries) = response else { throw Self.unexpected(response) }
    return entries.map(ProviderItem.init)
  }

  /// Downloads into a new file in `dir`. The item is read first, so if the file changes on the
  /// device in between, FileProvider holds newer contents under an older version and fetches it
  /// again, rather than older contents under a newer version, which it would keep. Anything but
  /// `.done` removes the file, which may hold a truncated prefix.
  public func fetch(_ id: NSFileProviderItemIdentifier, into dir: URL) async throws
    -> (URL, ProviderItem)
  {
    let itemID = try Self.itemID(id)
    let item = try await entry(.item(domain: domain, id: itemID))
    let url = dir.appending(path: UUID().uuidString, directoryHint: .notDirectory)
    let handle = try Self.createExclusively(url)
    do {
      defer { try? handle.close() }
      let response = try await send(.fetch(domain: domain, id: itemID), file: handle)
      guard case .done = response else { throw Self.unexpected(response) }
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return (url, ProviderItem(item))
  }

  /// Makes a folder, or uploads `contents` as a file. Symbolic links and aliases come with no
  /// contents, and MTP cannot store them.
  public func create(_ template: ItemTemplate, contents: URL?) async throws -> ProviderItem {
    let request = AgentRequest.create(
      domain: domain, parent: template.parent, name: template.filename,
      isFolder: template.isFolder)
    if template.isFolder {
      return ProviderItem(try await entry(request))
    }
    guard let contents else { throw CocoaError(.featureUnsupported) }
    let handle = try FileHandle(forReadingFrom: contents)
    defer { try? handle.close() }
    return ProviderItem(try await entry(request, file: handle))
  }

  /// Applies the changed fields in order: parent (move), then filename (rename), then contents.
  /// The item is read first when its parent or name may change, so a field reported as changed
  /// that names what the item already has sends nothing. The item keeps `id` throughout: a
  /// different identifier would tell FileProvider to merge the item into another.
  public func modify(
    _ id: NSFileProviderItemIdentifier, to template: ItemTemplate, changed: ItemChanges,
    contents: URL?
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
      latest = try await entry(.replaceContents(domain: domain, id: itemID), file: handle)
    }
    if let latest { return ProviderItem(latest) }
    return ProviderItem(try await entry(.item(domain: domain, id: itemID)))
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

  public func delete(_ id: NSFileProviderItemIdentifier) async throws {
    let response = try await send(.delete(domain: domain, id: try Self.itemID(id)))
    guard case .done = response else { throw Self.unexpected(response) }
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

  private func entry(_ request: AgentRequest, file: FileHandle? = nil) async throws
    -> ProviderEntry
  {
    let response = try await send(request, file: file)
    guard case .entry(let entry) = response else { throw Self.unexpected(response) }
    return entry
  }

  /// Sends `request`, turning a thrown error and a `.failure` reply alike into a FileProvider
  /// error.
  private func send(_ request: AgentRequest, file: FileHandle? = nil) async throws
    -> AgentResponse
  {
    let response: AgentResponse
    do {
      response = try await client.send(request, file: file)
    } catch {
      log.error(
        "\(String(describing: request), privacy: .private) failed: \(error, privacy: .private)")
      throw ErrorMapping.fileProviderError(error)
    }
    if case .failure(let error) = response {
      log.info(
        "\(String(describing: request), privacy: .private) refused: \(error, privacy: .private)")
      throw ErrorMapping.fileProviderError(error)
    }
    return response
  }

  private static func unexpected(_ response: AgentResponse) -> any Error {
    log.error("unexpected response from agent: \(String(describing: response), privacy: .private)")
    return ErrorMapping.fileProviderError(.io("Unexpected response from the Ferry agent."))
  }

  // MARK: Local mapping

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
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
