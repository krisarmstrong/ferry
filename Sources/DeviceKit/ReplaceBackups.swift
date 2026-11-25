import CryptoKit
import Foundation
import os

/// Local copies of device files a replace must delete before it can upload, on a device that
/// cannot rename (see `SafeWriter`), kept in a folder of the caller's own until the new file is
/// in place or the old one is back.
///
/// Each backup is three files: `<id>.data`, the original's bytes; `<id>.new`, a copy of the new
/// contents, so a later session can tell an upload of them the device cut short; and
/// `<id>.json`, its manifest, written only once both are complete and hashed. A manifest is what makes a backup real:
/// bytes with no manifest are a backup whose download never finished, before anything on the
/// device was touched, and `sweepIncomplete` removes them.
public struct ReplaceBackups: Sendable {
  public let folder: URL

  public init(folder: URL) {
    self.folder = folder
  }

  /// What a backup holds and what the replace meant to put in its place, so a later session can
  /// tell an unfinished replace (put the original back) from a finished one (drop the backup).
  struct Manifest: Codable, Equatable {
    let id: UUID
    let storage: StorageID
    let path: RemotePath
    let size: UInt64
    let sha256: String
    /// The file the replace was uploading in its place.
    let newSize: UInt64
    let newSHA256: String
  }

  struct Backup {
    let manifest: Manifest
    let data: URL
  }

  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "ReplaceBackups")

  /// Where a new backup's bytes go. The folder is made, private, if it is missing.
  func newDataFile() throws(TransportError) -> (id: UUID, url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw .io("cannot make the backup folder: \(error.localizedDescription)")
    }
    let id = UUID()
    return (id, dataFile(id))
  }

  /// A scratch file in the folder, for reading a device file back to check it.
  func scratchFile() -> URL {
    folder.appending(path: "\(UUID().uuidString).check")
  }

  /// Keeps a copy of the new contents beside the backup. On APFS the copy is a clone, which
  /// takes no space until either file changes.
  func keepNewContents(_ file: URL, for id: UUID) throws(TransportError) {
    do {
      try FileManager.default.copyItem(at: file, to: newFile(id))
    } catch {
      throw .io("cannot copy the new contents: \(error.localizedDescription)")
    }
  }

  /// Whether `file` holds the first bytes of the new contents of backup `id`, and fewer than all.
  func isStartOfNewContents(_ file: URL, for id: UUID) -> Bool {
    guard let start = try? FileHandle(forReadingFrom: file),
      let whole = try? FileHandle(forReadingFrom: newFile(id))
    else { return false }
    defer {
      try? start.close()
      try? whole.close()
    }
    // `read(upToCount:)` answers `nil` at the end of a file.
    do {
      while let chunk = try start.read(upToCount: 1 << 20), !chunk.isEmpty {
        guard try whole.read(upToCount: chunk.count) == chunk else { return false }
      }
      // All of `file` matched; it is a start only if the new contents go on.
      return try whole.read(upToCount: 1)?.isEmpty == false
    } catch {
      return false
    }
  }

  /// Records the backup whose bytes are complete at `dataFile(manifest.id)`.
  func commit(_ manifest: Manifest) throws(TransportError) -> Backup {
    do {
      try PrivateFile.write(JSONEncoder().encode(manifest), to: manifestFile(manifest.id))
    } catch {
      throw .io("cannot record the backup: \(error.localizedDescription)")
    }
    return Backup(manifest: manifest, data: dataFile(manifest.id))
  }

  /// The backups of files that were in `parent` on `storage`.
  func pending(in parent: RemotePath, storage: StorageID) -> [Backup] {
    manifests().filter { $0.storage == storage && $0.path.parent == parent }
      .map { Backup(manifest: $0, data: dataFile($0.id)) }
  }

  /// Every backup still held, for any device.
  func all() -> [Backup] {
    manifests().map { Backup(manifest: $0, data: dataFile($0.id)) }
  }

  /// Forgets a backup: its manifest first, so a failure part-way leaves bytes `sweepIncomplete`
  /// removes, never a manifest naming bytes that are gone.
  func remove(_ id: UUID) {
    unlink(manifestFile(id).path)
    unlink(dataFile(id).path)
    unlink(newFile(id).path)
  }

  /// Removes what an interrupted backup left: bytes with no manifest (the download never
  /// finished, so the device's file was never touched), a manifest whose bytes are gone, and
  /// scratch files. A manifest that cannot be read keeps its bytes: a backup is never deleted
  /// unless it is known to be unneeded. Run at start, before any write.
  public func sweepIncomplete() {
    let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    for name in names {
      let stem = (name as NSString).deletingPathExtension
      switch (name as NSString).pathExtension {
      case "check":
        unlink(folder.appending(path: name).path)
      case "data" where !names.contains(stem + ".json"),
        "new" where !names.contains(stem + ".json"):
        unlink(folder.appending(path: name).path)
      case "json" where !names.contains(stem + ".data"):
        Self.log.error("dropping a backup record whose copy is gone: \(name, privacy: .private)")
        unlink(folder.appending(path: name).path)
      default:
        continue
      }
    }
  }

  private func manifests() -> [Manifest] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
      guard let data = try? Data(contentsOf: folder.appending(path: name)),
        let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
        name == "\(manifest.id.uuidString).json"
      else { return nil }
      return manifest
    }
  }

  private func dataFile(_ id: UUID) -> URL {
    folder.appending(path: "\(id.uuidString).data")
  }

  private func newFile(_ id: UUID) -> URL {
    folder.appending(path: "\(id.uuidString).new")
  }

  private func manifestFile(_ id: UUID) -> URL {
    folder.appending(path: "\(id.uuidString).json")
  }
}

extension LocalFile {
  /// The SHA-256 of the file at `url`, in lowercase hex, read in chunks.
  public static func sha256(_ url: URL) throws(TransportError) -> String {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      throw .io("cannot read \(url.path): \(error.localizedDescription)")
    }
  }
}
