import Foundation

/// The agent's own stores (remembered devices, the tool file journal, the adb server it started)
/// name devices and where they are: they are never readable by another user, not even for a
/// moment.
public enum PrivateFile {
  /// Writes `data` to a new 0600 file beside `file`, flushes it, and renames it over `file`. A
  /// folder made for it is 0700. Nothing is left behind if any step fails.
  public static func write(_ data: Data, to file: URL) throws {
    let folder = file.deletingLastPathComponent()
    let temporary = folder.appending(path: ".\(file.lastPathComponent)-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let descriptor = open(
        temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path, file.path) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    } catch {
      unlink(temporary.path)
      throw error
    }
  }
}
