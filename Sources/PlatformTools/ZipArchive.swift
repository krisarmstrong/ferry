import Compression
import Foundation

/// A zip archive's entries, read from its central directory, and the contents of one entry on
/// request. Sizes and checksums come from the central directory: Google's archives put them after
/// each entry's data, not in its local header.
///
/// Reading refuses the whole archive if any entry could land outside its folder (an absolute
/// name, a `..`, a backslash) or is anything but a file or a folder (a symbolic link, a device),
/// and refuses an encrypted entry, a ZIP64 archive and any entry larger than `sizeLimit`.
struct ZipArchive {
  private struct Entry {
    let name: String
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
    var offset = directoryOffset
    for _ in 0..<count {
      guard try data.le32(at: offset) == 0x0201_4b50 else { throw .badArchive }
      let madeBy = try data.le16(at: offset + 4)
      let flags = try data.le16(at: offset + 8)
      let nameLength = Int(try data.le16(at: offset + 28))
      let extraLength = Int(try data.le16(at: offset + 30))
      let commentLength = Int(try data.le16(at: offset + 32))
      let attributes = try data.le32(at: offset + 38)
      let entry = Entry(
        name: try data.text(at: offset + 46, length: nameLength),
        method: try data.le16(at: offset + 10), crc: try data.le32(at: offset + 16),
        compressedSize: Int(try data.le32(at: offset + 20)),
        size: Int(try data.le32(at: offset + 24)),
        localHeader: Int(try data.le32(at: offset + 42)))
      guard flags & 0x0001 == 0, Self.isSafe(entry.name),
        madeBy >> 8 != 3 || Self.isFileOrFolder(mode: attributes >> 16),
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
    guard try data.le32(at: header) == 0x0403_4b50 else { throw .badArchive }
    let start =
      header + 30 + Int(try data.le16(at: header + 26))
      + Int(try data.le16(at: header + 28))
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

  /// A relative path that stays inside the archive's folder.
  private static func isSafe(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0")
    else { return false }
    var parts = name.split(separator: "/", omittingEmptySubsequences: false)
    if name.hasSuffix("/") { parts.removeLast() }
    return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  /// A Unix mode recording a regular file or a folder, or no type at all.
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
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { target in
      stored.withUnsafeBytes { source in
        compression_decode_buffer(
          target.bindMemory(to: UInt8.self).baseAddress!, size,
          source.bindMemory(to: UInt8.self).baseAddress!, stored.count, nil, COMPRESSION_ZLIB)
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
