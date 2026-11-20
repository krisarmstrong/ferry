import Compression
import Foundation

@testable import PlatformTools

/// Builds zip archives byte by byte, so a test can write what no zip tool would: names that
/// climb out of the folder, symbolic links, broken checksums. Each entry's sizes and checksum
/// go after its data and in the central directory only, as in Google's archive.
struct TestZip {
  struct Entry {
    var name: String
    var data: Data
    /// The Unix mode, file type included.
    var mode: UInt32 = 0o100_644
    var deflate = true
    /// Written in place of the real checksum when set.
    var crc: UInt32?
    var encrypted = false
    /// The host that made the entry, in the central directory: 3 is Unix, 0 MS-DOS.
    var madeBy: UInt16 = 3
    /// Written in the local header in place of the central directory's name or method.
    var localName: String?
    var localMethod: UInt16?
  }

  var entries: [Entry] = []

  mutating func add(
    _ name: String, _ text: String, mode: UInt32 = 0o100_644, deflate: Bool = true
  ) {
    entries.append(Entry(name: name, data: Data(text.utf8), mode: mode, deflate: deflate))
  }

  var data: Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
      let offset = UInt32(archive.count)
      let body = entry.deflate ? Self.deflated(entry.data) : entry.data
      let crc = entry.crc ?? ZipArchive.crc32(entry.data)
      let name = Data(entry.name.utf8)
      let localName = Data((entry.localName ?? entry.name).utf8)
      let flags: UInt16 = 0x0008 | 0x0800 | (entry.encrypted ? 0x0001 : 0)
      let method: UInt16 = entry.deflate ? 8 : 0
      archive.le32(0x0403_4b50)
      archive.le16(20)
      archive.le16(flags)
      archive.le16(entry.localMethod ?? method)
      archive.le32(0)  // time and date
      archive.le32(0)  // checksum and sizes follow the data
      archive.le32(0)
      archive.le32(0)
      archive.le16(UInt16(localName.count))
      archive.le16(0)
      archive.append(localName)
      archive.append(body)
      archive.le32(0x0807_4b50)
      archive.le32(crc)
      archive.le32(UInt32(body.count))
      archive.le32(UInt32(entry.data.count))

      central.le32(0x0201_4b50)
      central.le16(entry.madeBy << 8 | 21)
      central.le16(20)
      central.le16(flags)
      central.le16(method)
      central.le32(0)
      central.le32(crc)
      central.le32(UInt32(body.count))
      central.le32(UInt32(entry.data.count))
      central.le16(UInt16(name.count))
      central.le16(0)
      central.le16(0)
      central.le16(0)
      central.le16(0)
      central.le32(entry.mode << 16)
      central.le32(offset)
      central.append(name)
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.le32(0x0605_4b50)
    archive.le16(0)
    archive.le16(0)
    archive.le16(UInt16(entries.count))
    archive.le16(UInt16(entries.count))
    archive.le32(UInt32(central.count))
    archive.le32(centralOffset)
    archive.le16(0)
    return archive
  }

  /// Raw deflate, as zip stores it.
  static func deflated(_ data: Data) -> Data {
    let capacity = data.count + 1024
    var output = [UInt8](repeating: 0, count: capacity)
    let source = [UInt8](data)
    let written = compression_encode_buffer(
      &output, capacity, source, source.count, nil, COMPRESSION_ZLIB)
    return Data(output[..<written])
  }
}

extension Data {
  mutating func le16(_ value: UInt16) {
    append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)])
  }

  mutating func le32(_ value: UInt32) {
    le16(UInt16(value & 0xffff))
    le16(UInt16(value >> 16))
  }
}
