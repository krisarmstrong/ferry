import DeviceKit
import FerryIPC
import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ProviderBackend")

/// Everything the FileProvider extension does for one domain, forwarded to the agent.
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
    ProviderItem(try await remoteItem(try Self.path(of: id)))
  }

  /// The working set is empty: Ferry does not track items outside the folders Finder lists.
  public func children(of id: NSFileProviderItemIdentifier) async throws -> [ProviderItem] {
    if id == .workingSet { return [] }
    let response = try await send(.list(domain: domain, folder: try Self.path(of: id)))
    guard case .items(let items) = response else { throw Self.unexpected(response) }
    return items.map(ProviderItem.init)
  }

  /// Downloads into a new file in `dir`. The item is read first, so if the file changes on the
  /// device in between, FileProvider holds newer contents under an older version and fetches it
  /// again, rather than older contents under a newer version, which it would keep. Anything but
  /// `.done` removes the file, which may hold a truncated prefix.
  public func fetch(_ id: NSFileProviderItemIdentifier, into dir: URL) async throws
    -> (URL, ProviderItem)
  {
    let path = try Self.path(of: id)
    let item = try await remoteItem(path)
    let url = dir.appending(path: UUID().uuidString, directoryHint: .notDirectory)
    let handle = try Self.createExclusively(url)
    do {
      defer { try? handle.close() }
      let response = try await send(.fetch(domain: domain, path: path), file: handle)
      guard case .done = response else { throw Self.unexpected(response) }
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return (url, ProviderItem(item))
  }

  /// Makes a folder, or uploads `contents` as a file. Symbolic links and aliases come with no
  /// contents, and MTP cannot store them.
  public func create(_ template: any NSFileProviderItem, contents: URL?) async throws
    -> ProviderItem
  {
    let parent = try Self.path(of: template.parentItemIdentifier)
    let path = try Self.mapped { () throws(TransportError) in
      try parent.appending(template.filename)
    }
    if template.contentType?.conforms(to: .folder) == true {
      return try await itemResponse(.create(domain: domain, path: path, isFolder: true))
    }
    guard let contents else { throw CocoaError(.featureUnsupported) }
    let handle = try FileHandle(forReadingFrom: contents)
    defer { try? handle.close() }
    return try await itemResponse(
      .create(domain: domain, path: path, isFolder: false), file: handle)
  }

  /// Applies the changed fields in order: parent (move), then filename (rename), then contents.
  /// A field reported as changed that names what the item already has sends nothing. Other
  /// fields, such as dates and tags, have nowhere to go on an MTP device.
  public func modify(
    _ item: any NSFileProviderItem, changed: NSFileProviderItemFields, contents: URL?
  ) async throws -> ProviderItem {
    var path = try Self.path(of: item.itemIdentifier)
    let folder = try Self.path(of: item.parentItemIdentifier)
    let filename = item.filename
    var latest: RemoteItem?

    if changed.contains(.parentItemIdentifier), path.parent != folder {
      let moved = try await itemResponse(.move(domain: domain, path: path, toFolder: folder))
      latest = moved.remote
      path = moved.remote.path
    }
    if changed.contains(.filename), let parent = path.parent {
      let renamed = try Self.mapped { () throws(TransportError) in
        try parent.appending(filename)
      }
      // Compared as paths, so another normal form of the same name is no change, but a change
      // of case is: the agent lets an item take a name only its own name collides with.
      if renamed != path {
        let item = try await itemResponse(.rename(domain: domain, path: path, to: filename))
        latest = item.remote
        path = item.remote.path
      }
    }
    if changed.contains(.contents), let contents {
      let handle = try FileHandle(forReadingFrom: contents)
      defer { try? handle.close() }
      let item = try await itemResponse(
        .replaceContents(domain: domain, path: path), file: handle)
      latest = item.remote
    }
    if let latest { return ProviderItem(latest) }
    return ProviderItem(try await remoteItem(path))
  }

  public func delete(_ id: NSFileProviderItemIdentifier) async throws {
    let response = try await send(.delete(domain: domain, path: try Self.path(of: id)))
    guard case .done = response else { throw Self.unexpected(response) }
  }

  // MARK: Requests

  private func remoteItem(_ path: RemotePath) async throws -> RemoteItem {
    try await itemResponse(.item(domain: domain, path: path)).remote
  }

  private func itemResponse(_ request: AgentRequest, file: FileHandle? = nil) async throws
    -> ProviderItem
  {
    let response = try await send(request, file: file)
    guard case .item(let item) = response else { throw Self.unexpected(response) }
    return ProviderItem(item)
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

  /// Every identifier other than the root is a path. The trash, the working set and anything
  /// else that does not parse name no item on the device.
  private static func path(of id: NSFileProviderItemIdentifier) throws -> RemotePath {
    if id == .rootContainer { return .root }
    guard id.rawValue.hasPrefix("/"), let path = try? RemotePath(id.rawValue), path != .root
    else { throw NSFileProviderError(.noSuchItem) }
    return path
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
