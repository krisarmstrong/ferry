import DeviceKit
import Foundation

// MARK: Downloading

extension MTPSession {
  /// Downloads into a hidden partial beside `file` and renames it over `file` only once it is
  /// whole, so a failed or short download leaves nothing at `file` and leaves a file already
  /// there untouched. Without `replacing`, a file at `file` is `.alreadyExists(path)` even if it
  /// appeared while the download ran.
  ///
  /// Whole means at least the size the device lists. A device's metadata can be stale (an app
  /// rewrote the file), and libmtp has reported the transfer complete, so more bytes than
  /// listed are the file; the result says how many arrived. Fewer is a transfer cut short: it is
  /// tried once more, then reported.
  @discardableResult
  func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded {
    try await operation { () throws(TransportError) in
      let raw = try await raw(storage)
      var entry = try await entry(path, storage: raw)
      var attempt = 1
      while true {
        guard !entry.isFolder else { throw .notFound(path) }
        do throws(TransportError) {
          return try await downloadOnce(
            entry, of: path, to: file, replacing: replacing, progress: progress)
        } catch .downloadSizeMismatch(let listed, let received) {
          guard received < listed, attempt < Self.downloadAttempts else {
            throw .downloadSizeMismatch(listed: listed, received: received)
          }
          Self.log.info("download cut short (\(received) of \(listed) bytes); trying again")
          entry = try await freshEntry(path, storage: raw)
        } catch {
          // The cached object may be one the device has since replaced: download the new one.
          guard attempt < Self.downloadAttempts else { throw error }
          entry = try await relisted(path, after: error, on: entry, storage: raw)
        }
        attempt += 1
      }
    }
  }

  private static let downloadAttempts = 2

  private func downloadOnce(
    _ entry: MTPEntry, of path: RemotePath, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded {
    try LocalFile.requireSpace(entry.size, at: file.deletingLastPathComponent())
    let partial = file.deletingLastPathComponent()
      .appendingPathComponent(SafeWriter.partialPrefix + UUID().uuidString)
    do throws(TransportError) {
      try await device.download(objectID: entry.objectID, to: partial, progress: progress)
      let size = try LocalFile.regularFileSize(partial)
      guard size >= entry.size else {
        throw .downloadSizeMismatch(listed: entry.size, received: size)
      }
      try Self.place(partial, at: file, replacing: replacing, downloadOf: path)
      return Downloaded(listed: Self.item(entry, at: path), received: size)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }
}

extension MTPSession {
  /// Moves a finished download from `partial` to `file`. Both renames are atomic, so `file` is
  /// either what was there before or the complete download.
  private static func place(
    _ partial: URL, at file: URL, replacing: Bool, downloadOf path: RemotePath
  ) throws(TransportError) {
    if replacing {
      guard Darwin.rename(partial.path, file.path) == 0 else { throw saveFailed(file, errno) }
      return
    }
    guard renamex_np(partial.path, file.path, UInt32(RENAME_EXCL)) != 0 else { return }
    let failure = errno
    switch failure {
    case EEXIST:
      throw .alreadyExists(path)
    case ENOTSUP:
      // Not every volume supports an exclusive rename; checking first narrows the race.
      log.warning(
        "exclusive rename unsupported for \(file.path, privacy: .private); checking first")
      guard !FileManager.default.fileExists(atPath: file.path) else {
        throw .alreadyExists(path)
      }
      guard Darwin.rename(partial.path, file.path) == 0 else { throw saveFailed(file, errno) }
    default:
      throw saveFailed(file, failure)
    }
  }

  private static func saveFailed(_ file: URL, _ code: Int32) -> TransportError {
    .io("saving \(file.path) failed: \(String(cString: strerror(code)))")
  }
}
