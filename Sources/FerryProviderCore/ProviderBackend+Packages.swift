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
