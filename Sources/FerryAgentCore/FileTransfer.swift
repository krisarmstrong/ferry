import DeviceKit
import Foundation

/// Moves file contents between a descriptor a client sent and a file only the agent names.
///
/// The agent never opens a path a client chose. A sandboxed client could otherwise swap a folder
/// in its container for a symlink between the agent's check and its use, and have the agent read
/// or write outside the client's sandbox. Copies stream in chunks, so size is not limited, and use
/// positional reads and writes, so neither descriptor's current offset matters.
public enum FileTransfer {
  private static let chunk = 1 << 20

  private static let scratchPrefix = "ferry-transfer-"

  /// A new path in the agent's own temporary directory, with nothing there yet.
  static func scratchURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: scratchPrefix + UUID().uuidString)
  }

  /// Deletes the scratch files, the partial downloads beside them and the copies a move left
  /// mid-way, that an agent which
  /// stopped mid-transfer left in `folder`. Run at start, before any transfer.
  public static func sweep(_ folder: URL = FileManager.default.temporaryDirectory) {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch {
      return
    }
    let scratch = [scratchPrefix, LocalFile.moveScratchPrefix]
    for name in names
    where scratch.contains(where: name.hasPrefix) || SafeWriter.isPartial(name) {
      remove(folder.appending(path: name))
    }
  }

  /// Deletes a scratch file. One that was never created is already gone.
  static func remove(_ url: URL) {
    unlink(url.path)
  }

  /// Throws unless `descriptor` is a regular file: a pipe, socket, device or folder is refused.
  static func requireRegular(_ descriptor: Int32) throws(TransportError) {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw .io("cannot inspect file: \(errorText())") }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .io("not a regular file") }
  }

  /// Copies all of `source`, a regular file, into a new scratch file and returns its URL.
  @concurrent static func copyIn(_ source: Int32) async throws(TransportError) -> URL {
    try requireRegular(source)
    var info = stat()
    guard fstat(source, &info) == 0 else { throw .io("cannot inspect file: \(errorText())") }
    let url = scratchURL()
    try LocalFile.requireSpace(UInt64(clamping: info.st_size), at: url.deletingLastPathComponent())
    let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw .io("cannot create transfer file: \(errorText())") }
    defer { close(output) }
    do throws(TransportError) {
      try copy(from: source, to: output)
    } catch {
      remove(url)
      throw error
    }
    return url
  }

  /// Replaces the contents of `target`, a regular file, with the scratch file at `url`, and
  /// flushes it to disk.
  @concurrent static func copyOut(_ url: URL, to target: Int32) async throws(TransportError) {
    let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { throw .io("cannot open transfer file: \(errorText())") }
    defer { close(input) }
    var info = stat()
    guard fstat(input, &info) == 0 else { throw .io("cannot inspect file: \(errorText())") }
    try LocalFile.requireSpace(UInt64(clamping: info.st_size), onVolumeOf: target)
    guard ftruncate(target, 0) == 0 else { throw .io("cannot truncate file: \(errorText())") }
    try copy(from: input, to: target)
    guard fsync(target) == 0 else { throw .io("cannot flush file: \(errorText())") }
  }

  private static func copy(from input: Int32, to output: Int32) throws(TransportError) {
    var buffer = [UInt8](repeating: 0, count: chunk)
    var offset: off_t = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress, chunk, offset) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .io("reading failed: \(errorText())")
      }
      if count == 0 { return }
      try write(buffer, count: count, to: output, at: offset)
      offset += off_t(count)
    }
  }

  private static func write(_ buffer: [UInt8], count: Int, to output: Int32, at offset: off_t)
    throws(TransportError)
  {
    var written = 0
    while written < count {
      let result = buffer.withUnsafeBytes { bytes in
        pwrite(
          output, bytes.baseAddress?.advanced(by: written), count - written,
          offset + off_t(written))
      }
      if result < 0 {
        if errno == EINTR { continue }
        throw .io("writing failed: \(errorText())")
      }
      written += result
    }
  }

  private static func errorText() -> String {
    String(cString: strerror(errno))
  }
}
