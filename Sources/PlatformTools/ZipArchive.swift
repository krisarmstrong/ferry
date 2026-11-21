import Compression
import Foundation

/// A zip archive's entries, read from its central directory, and the contents of one entry on
/// request. Sizes and checksums come from the central directory: Google's archives put them after
/// each entry's data, not in its local header.
///
/// Reading refuses the whole archive if any entry's name is not a plain relative path (anything
/// but ASCII letters, digits and `._+-/`, an absolute name, an empty, `.` or `..` component), if
/// two entries share a name, if any entry's mode is a symbolic link, a device or anything but a
/// file or a folder (whichever host made it), and refuses an encrypted entry, a ZIP64 archive and
/// any entry larger than `sizeLimit`. An entry is read only if its local header agrees with the
/// central directory: name, method, the encrypted and data-descriptor flags, and any sizes and
/// checksum it records. Names are only ever compared, never used as paths.
struct ZipArchive {
  private struct Entry {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let size: Int
    let localHeader: Int
  }

  /// Google's `adb` is about 20 MB; nothing Ferry takes is anywhere near this.
  static let sizeLimit = 64 << 20

  private let data: Data
  private let entries: [Entry]

  var names: [String] { entries.map(\.name) }

  init(_ archive: Data) throws(PlatformToolsError) {
    // Indices from zero, whatever slice was passed.
    let data = Data(archive)
    let end = try Self.endOfCentralDirectory(in: data)
    let count = Int(try data.le16(at: end + 10))
    let directorySize = Int(try data.le32(at: end + 12))
    let directoryOffset = Int(try data.le32(at: end + 16))
    guard try data.le16(at: end + 4) == 0, try data.le16(at: end + 6) == 0,
      count != 0xffff, directoryOffset != 0xffff_ffff,
      directoryOffset + directorySize <= end
    else { throw .badArchive }
    var entries: [Entry] = []
    var names = Set<String>()
    var offset = directoryOffset
    for _ in 0..<count {
      guard try data.le32(at: offset) == 0x0201_4b50 else { throw .badArchive }
      let flags = try data.le16(at: offset + 8)
      let nameLength = Int(try data.le16(at: offset + 28))
      let extraLength = Int(try data.le16(at: offset + 30))
      let commentLength = Int(try data.le16(at: offset + 32))
      let attributes = try data.le32(at: offset + 38)
      let entry = Entry(
        name: try data.text(at: offset + 46, length: nameLength), flags: flags,
        method: try data.le16(at: offset + 10), crc: try data.le32(at: offset + 16),
        compressedSize: Int(try data.le32(at: offset + 20)),
        size: Int(try data.le32(at: offset + 24)),
        localHeader: Int(try data.le32(at: offset + 42)))
      guard flags & 0x0001 == 0, Self.isSafe(entry.name), names.insert(entry.name).inserted,
        Self.isFileOrFolder(mode: attributes >> 16),
        entry.size <= Self.sizeLimit, entry.compressedSize <= Self.sizeLimit,
        entry.localHeader < directoryOffset
      else { throw .badArchive }
      entries.append(entry)
      offset += 46 + nameLength + extraLength + commentLength
    }
    guard offset == directoryOffset + directorySize else { throw .badArchive }
    self.data = data
    self.entries = entries
  }

  /// The entry's contents, checked against its checksum; `nil` if the archive has no such entry.
  func contents(of name: String) throws(PlatformToolsError) -> Data? {
    guard let entry = entries.first(where: { $0.name == name }) else { return nil }
    let header = entry.localHeader
    let nameLength = Int(try data.le16(at: header + 26))
    guard try data.le32(at: header) == 0x0403_4b50,
      try data.le16(at: header + 6) & Self.checkedFlags == entry.flags & Self.checkedFlags,
      try data.le16(at: header + 8) == entry.method,
      try data.text(at: header + 30, length: nameLength) == entry.name,
      try Self.agrees(data.le32(at: header + 14), entry.crc, entry.flags),
      try Self.agrees(data.le32(at: header + 18), UInt32(entry.compressedSize), entry.flags),
      try Self.agrees(data.le32(at: header + 22), UInt32(entry.size), entry.flags)
    else { throw .badArchive }
    let start = header + 30 + nameLength + Int(try data.le16(at: header + 28))
    guard start + entry.compressedSize <= data.count else { throw .badArchive }
    let stored = data[start..<start + entry.compressedSize]
    let contents: Data
    switch entry.method {
    case 0:
      contents = stored
    case 8:
      contents = try Self.inflate(stored, size: entry.size)
    default:
      throw .badArchive
    }
    guard contents.count == entry.size, Self.crc32(contents) == entry.crc else {
      throw .badArchive
    }
    return Data(contents)
  }

  /// The encrypted and data-descriptor flags, which the local header must repeat.
  private static let checkedFlags: UInt16 = 0x0009

  /// A local header's checksum or size: the central directory's, or zero when the entry's data
  /// descriptor carries it instead.
  private static func agrees(_ local: UInt32, _ central: UInt32, _ flags: UInt16) -> Bool {
    local == central || (flags & 0x0008 != 0 && local == 0)
  }

  /// A plain relative path: ASCII letters, digits and `._+-/`, no empty, `.` or `..` component.
  private static func isSafe(_ name: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-/")
    guard !name.isEmpty, !name.hasPrefix("/"), name.allSatisfy(allowed.contains)
    else { return false }
    var parts = name.split(separator: "/", omittingEmptySubsequences: false)
    if name.hasSuffix("/") { parts.removeLast() }
    return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  /// A Unix mode recording a regular file or a folder, or no mode at all.
  private static func isFileOrFolder(mode: UInt32) -> Bool {
    [0, 0o100_000, 0o040_000].contains(mode & 0o170_000)
  }

  private static func endOfCentralDirectory(in data: Data) throws(PlatformToolsError) -> Int {
    // The record is 22 bytes, followed by a comment of at most 65,535.
    guard data.count >= 22 else { throw .badArchive }
    let last = data.count - 22
    for offset in stride(from: last, through: max(0, last - 0xffff), by: -1)
    where (try? data.le32(at: offset)) == 0x0605_4b50 {
      return offset
    }
    throw .badArchive
  }

  private static func inflate(_ stored: Data, size: Int) throws(PlatformToolsError) -> Data {
    guard size > 0 else { return Data() }
    guard !stored.isEmpty else { throw .badArchive }
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { target in
      stored.withUnsafeBytes { source -> Int in
        guard let target = target.bindMemory(to: UInt8.self).baseAddress,
          let source = source.bindMemory(to: UInt8.self).baseAddress
        else { return 0 }
        return compression_decode_buffer(
          target, size, source, stored.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw .badArchive }
    return output
  }

  private static let crcTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1 }
    return value
  }

  /// CRC-32 as zip uses it (IEEE 802.3, reflected).
  static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    crcTable.withUnsafeBufferPointer { table in
      data.withUnsafeBytes { bytes in
        for byte in bytes {
          crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
      }
    }
    return ~crc
  }
}

extension Data {
  fileprivate func le16(at offset: Int) throws(PlatformToolsError) -> UInt16 {
    guard offset >= 0, offset + 2 <= count else { throw .badArchive }
    return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func le32(at offset: Int) throws(PlatformToolsError) -> UInt32 {
    UInt32(try le16(at: offset)) | UInt32(try le16(at: offset + 2)) << 16
  }

  fileprivate func text(at offset: Int, length: Int) throws(PlatformToolsError) -> String {
    guard offset >= 0, offset + length <= count,
      let text = String(bytes: self[offset..<offset + length], encoding: .utf8)
    else { throw .badArchive }
    return text
  }
}
