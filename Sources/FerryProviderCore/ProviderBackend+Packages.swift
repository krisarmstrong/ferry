import DeviceKit
import FerryIPC
import FileProvider
import Foundation

// MARK: Packages

/// FileProvider syncs a package (an `.rtfd` document, an app) as one item whose contents are its
/// folder. On the device it is a folder, so these copy that folder's tree, and keep it in line
/// when the package is edited.
extension ProviderBackend {
  /// Copies the folder at `local` into the device folder `parent`: subfolders and regular
  /// files, depth first. Symbolic links inside it have nothing MTP can store and are left out.
  func uploadTree(_ local: URL, into parent: ItemID) async throws {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let children = try FileManager.default.contentsOfDirectory(
      at: local, includingPropertiesForKeys: keys)
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let values = try child.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true { continue }
      let name = child.lastPathComponent
      if values.isDirectory == true {
        let folder = try await entry(
          .create(domain: domain, parent: parent, name: name, isFolder: true))
        try await uploadTree(child, into: folder.id)
      } else if values.isRegularFile == true {
        let handle = try FileHandle(forReadingFrom: child)
        defer { try? handle.close() }
        _ = try await entry(
          .create(domain: domain, parent: parent, name: name, isFolder: false), file: handle)
      }
    }
  }

  /// Brings the device folder `folder` in line with the local folder `local`, for a package
  /// FileProvider sends as one item. A file goes up if it is new, a different size, or changed on
  /// the Mac since the device's copy was written; a subfolder is followed; anything on the device
  /// the package no longer has is deleted, with its contents. An item that changed kind is
  /// replaced. Links are left out, as when the package was first copied.
  func syncTree(_ local: URL, into folder: ItemID) async throws {
    let response = try await send(.list(domain: domain, folder: folder))
    guard case .entries(let entries) = response else { throw Self.unexpected(response) }
    var onDevice = Dictionary(
      entries.compactMap { entry in entry.item.path.name.map { ($0, entry) } },
      uniquingKeysWith: { first, _ in first })
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      .contentModificationDateKey,
    ]
    let children = try FileManager.default.contentsOfDirectory(
      at: local, includingPropertiesForKeys: keys)
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let values = try child.resourceValues(forKeys: Set(keys))
      guard values.isSymbolicLink != true else { continue }
      let existing = onDevice.removeValue(forKey: child.lastPathComponent)
      if values.isDirectory == true {
        try await syncFolder(child, existing, in: folder)
      } else if values.isRegularFile == true {
        try await syncFile(child, values, existing, in: folder)
      }
    }
    for gone in onDevice.values {
      try await deleteFromPackage(gone)
    }
  }

  private func deleteFromPackage(_ entry: ProviderEntry) async throws {
    let response = try await send(
      .delete(domain: domain, id: entry.id, base: nil, recursive: true))
    guard case .done = response else { throw Self.unexpected(response) }
  }

  private func syncFolder(_ child: URL, _ existing: ProviderEntry?, in folder: ItemID)
    async throws
  {
    if let existing, existing.item.kind == .folder {
      try await syncTree(child, into: existing.id)
      return
    }
    if let existing { try await deleteFromPackage(existing) }
    let made = try await entry(
      .create(domain: domain, parent: folder, name: child.lastPathComponent, isFolder: true))
    try await uploadTree(child, into: made.id)
  }

  private func syncFile(
    _ child: URL, _ values: URLResourceValues, _ existing: ProviderEntry?, in folder: ItemID
  ) async throws {
    let handle = try FileHandle(forReadingFrom: child)
    defer { try? handle.close() }
    guard let existing, existing.item.kind == .file else {
      if let existing { try await deleteFromPackage(existing) }
      _ = try await entry(
        .create(domain: domain, parent: folder, name: child.lastPathComponent, isFolder: false),
        file: handle)
      return
    }
    let size = UInt64(values.fileSize ?? 0)
    let modified = values.contentModificationDate ?? .distantFuture
    guard size != existing.item.size || modified > existing.item.modified else { return }
    _ = try await entry(
      .replaceContents(domain: domain, id: existing.id, base: nil, onConflict: .keepBoth),
      file: handle)
  }
}

// MARK: Budget

extension ProviderBackend {
  /// Walks the local tree at `local` before any of it is sent, and refuses one deeper, with more
  /// entries or more bytes than `budget` allows, with the description Finder shows.
  static func requireWithinBudget(_ local: URL, _ budget: TreeBudget) throws {
    var usage = TreeBudget.Usage(budget)
    do throws(TransportError) {
      try measure(local, depth: 1, usage: &usage)
    } catch {
      throw ErrorMapping.fileProviderError(error)
    }
  }

  private static func measure(_ folder: URL, depth: Int, usage: inout TreeBudget.Usage)
    throws(TransportError)
  {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys)
    } catch {
      throw .io("reading \(folder.lastPathComponent) failed: \(error.localizedDescription)")
    }
    for child in children {
      let values = try? child.resourceValues(forKeys: Set(keys))
      guard values?.isSymbolicLink != true else { continue }
      if values?.isDirectory == true {
        try usage.add(depth: depth)
        try measure(child, depth: depth + 1, usage: &usage)
      } else if values?.isRegularFile == true {
        try usage.add(depth: depth, size: try LocalFile.regularFileSize(child))
      }
    }
  }
}

// MARK: Document packages

extension ProviderBackend {
  /// Sends the local package folder `folder` as one archive with `request`, a `.createPackage`
  /// or `.replacePackage`, and returns the package as the agent made it.
  func sendingPackage(_ folder: URL, as request: AgentRequest) async throws -> ProviderEntry {
    let archive = FileManager.default.temporaryDirectory.appending(
      path: "ferry-package-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: archive) }
    guard FileManager.default.createFile(atPath: archive.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: archive)
    do throws(TransportError) {
      defer { try? writer.close() }
      try PackageArchive.write(tree: folder, to: writer, budget: treeBudget)
    } catch {
      throw ErrorMapping.fileProviderError(error)
    }
    let reader = try FileHandle(forReadingFrom: archive)
    defer { try? reader.close() }
    return try await entry(request, file: reader)
  }

  /// Extracts the archive at `archive` into a new folder in `dir` and returns it, with every
  /// folder and file in it, and the folder itself, carrying `quarantine` as
  /// `com.apple.quarantine`: FileProvider sets an item's attributes on the package itself only.
  static func unpack(_ archive: URL, in dir: URL, quarantine: Data) throws -> URL {
    let folder = dir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let reader = try FileHandle(forReadingFrom: archive)
    defer { try? reader.close() }
    do throws(TransportError) {
      try PackageArchive.extract(from: reader, to: folder, quarantine: quarantine)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw ErrorMapping.fileProviderError(error)
    }
    return folder
  }
}
