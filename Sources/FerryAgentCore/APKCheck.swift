import Foundation

/// Whether a file is an Android app: a ZIP (local header magic at the start) whose central
/// directory lists `AndroidManifest.xml` at its root. The name or extension decides nothing.
///
/// ZIP64 is refused: Android's own APK tooling (`apksig`) refuses it too, so no installable APK
/// uses it, and the 4 GB cap keeps every offset within the classic fields.
enum APKCheck {
  private static let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
  private static let endOfDirectory: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
  private static let directoryEntry: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
  private static let manifest = Array("AndroidManifest.xml".utf8)
  /// The end record (22 bytes) plus the longest comment a ZIP can carry.
  private static let tailLimit = 22 + 0xFFFF
  /// A central directory this large lists far more entries than any app has.
  private static let directoryLimit = 64 << 20

  static func isAPK(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size >= 22,
      read(handle, at: 0, count: 4) == localHeader
    else { return false }
    let tailStart = size - UInt64(min(UInt64(tailLimit), size))
    guard let tail = read(handle, at: tailStart, count: Int(size - tailStart)),
      let end = endRecord(in: tail)
    else { return false }
    let entries = word16(tail, end + 10)
    let directorySize = UInt64(word32(tail, end + 12))
    let directoryOffset = UInt64(word32(tail, end + 16))
    guard entries != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
      directorySize <= UInt64(directoryLimit),
      directoryOffset + directorySize <= tailStart + UInt64(end),
      let directory = read(handle, at: directoryOffset, count: Int(directorySize))
    else { return false }
    return lists(manifest, in: directory)
  }

  /// The offset in `tail` of the end-of-central-directory record: the last signature whose
  /// comment runs exactly to the end of the file.
  private static func endRecord(in tail: [UInt8]) -> Int? {
    var index = tail.count - 22
    while index >= 0 {
      let commentEnd = index + 22 + Int(word16(tail, index + 20))
      if Array(tail[index..<index + 4]) == endOfDirectory, commentEnd == tail.count { return index }
      index -= 1
    }
    return nil
  }

  private static func lists(_ name: [UInt8], in directory: [UInt8]) -> Bool {
    var index = 0
    while index + 46 <= directory.count, Array(directory[index..<index + 4]) == directoryEntry {
      let nameLength = Int(word16(directory, index + 28))
      let extraLength = Int(word16(directory, index + 30))
      let commentLength = Int(word16(directory, index + 32))
      let nameEnd = index + 46 + nameLength
      guard nameEnd <= directory.count else { return false }
      if Array(directory[(index + 46)..<nameEnd]) == name { return true }
      index = nameEnd + extraLength + commentLength
    }
    return false
  }

  private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
    guard (try? handle.seek(toOffset: offset)) != nil,
      let data = try? handle.read(upToCount: count), data.count == count
    else { return nil }
    return Array(data)
  }

  private static func word16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func word32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
  }
}
