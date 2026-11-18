import Foundation

/// Facts about a file on the Mac side of a transfer.
public enum LocalFile {
  /// The size of the regular file at `url`, after following symlinks.
  ///
  /// An upload declares this size up front and libmtp sends exactly that many bytes, so a link's
  /// own size would truncate the file. Anything but a regular file, or a size that cannot be
  /// read, is `.io`.
  public static func regularFileSize(_ url: URL) throws(TransportError) -> UInt64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    let values: URLResourceValues
    do {
      values = try url.resolvingSymlinksInPath().resourceValues(forKeys: keys)
    } catch {
      throw .io(error.localizedDescription)
    }
    guard values.isRegularFile == true else { throw .io("\(url.path) is not a regular file") }
    guard let size = values.fileSize else { throw .io("cannot read the size of \(url.path)") }
    return UInt64(size)
  }

  /// The prefix of the file a move on a device without MoveObject copies through.
  public static let moveScratchPrefix = "ferry-move-"

  /// Throws `.macDiskFull` unless the volume holding `url` has `needed` bytes free.
  public static func requireSpace(_ needed: UInt64, at url: URL) throws(TransportError) {
    var info = statfs()
    guard statfs(url.path, &info) == 0 else { return }
    try requireSpace(needed, free: available(info))
  }

  /// Throws `.macDiskFull` unless the volume of the open file `descriptor` has `needed` bytes
  /// free.
  public static func requireSpace(_ needed: UInt64, onVolumeOf descriptor: Int32)
    throws(TransportError)
  {
    var info = statfs()
    guard fstatfs(descriptor, &info) == 0 else { return }
    try requireSpace(needed, free: available(info))
  }

  private static func requireSpace(_ needed: UInt64, free: UInt64) throws(TransportError) {
    if needed > free { throw .macDiskFull(needed: needed, free: free) }
  }

  /// Bytes an unprivileged process may still write, saturating rather than overflowing.
  private static func available(_ info: statfs) -> UInt64 {
    let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(
      by: UInt64(info.f_bsize))
    return overflow ? .max : bytes
  }
}
