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
}
