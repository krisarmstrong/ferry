import Foundation
import Testing

@testable import PlatformTools

struct ZipArchiveTests {
  private func archive(_ build: (inout TestZip) -> Void) throws(PlatformToolsError) -> ZipArchive {
    var zip = TestZip()
    build(&zip)
    return try ZipArchive(zip.data)
  }

  @Test func readsStoredAndDeflatedEntries() throws {
    let zip = try archive {
      $0.add("platform-tools/", "", mode: 0o040_755, deflate: false)
      $0.add("platform-tools/adb", String(repeating: "adb ", count: 5000), mode: 0o100_755)
      $0.add("platform-tools/NOTICE.txt", "notice", deflate: false)
    }
    #expect(
      try zip.contents(of: "platform-tools/adb")
        == Data(String(repeating: "adb ", count: 5000).utf8))
    #expect(try zip.contents(of: "platform-tools/NOTICE.txt") == Data("notice".utf8))
    #expect(zip.names == ["platform-tools/", "platform-tools/adb", "platform-tools/NOTICE.txt"])
  }

  @Test func aMissingEntryIsNil() throws {
    let zip = try archive { $0.add("platform-tools/adb", "adb") }
    #expect(try zip.contents(of: "platform-tools/fastboot") == nil)
  }

  /// Any one unsafe entry rejects the whole archive, wanted or not.
  @Test(arguments: [
    "platform-tools/../../Library/LaunchAgents/x.plist", "../adb", "/usr/local/bin/adb",
    "platform-tools\\..\\adb", "platform-tools/./adb", "", "platform-tools//adb",
  ])
  func rejectsANameOutsideTheFolder(name: String) {
    #expect(throws: PlatformToolsError.self) {
      try archive {
        $0.add("platform-tools/adb", "adb")
        $0.add(name, "x")
      }
    }
  }

  @Test(arguments: [UInt32(0o120_777), 0o060_644, 0o010_644, 0o140_755])
  func rejectsALinkOrADevice(mode: UInt32) {
    #expect(throws: PlatformToolsError.self) {
      try archive { $0.add("platform-tools/adb", "/bin/sh", mode: mode) }
    }
  }

  /// Whatever host made the entry: a link's mode under MS-DOS is still a link.
  @Test(arguments: [UInt16(0), 3, 19])
  func rejectsALinkMadeByAnyHost(madeBy: UInt16) {
    #expect(throws: PlatformToolsError.self) {
      var zip = TestZip()
      zip.entries.append(
        .init(
          name: "platform-tools/adb", data: Data("/bin/sh".utf8), mode: 0o120_777, madeBy: madeBy))
      _ = try ZipArchive(zip.data)
    }
  }

  /// The local header must say what the central directory says.
  @Test func rejectsALocalHeaderThatDisagrees() throws {
    var renamed = TestZip()
    renamed.entries.append(
      .init(name: "platform-tools/adb", data: Data("adb".utf8), localName: "../../../evil"))
    var remethoded = TestZip()
    remethoded.entries.append(
      .init(name: "platform-tools/adb", data: Data("adb".utf8), deflate: false, localMethod: 8))
    for zip in [renamed, remethoded] {
      let archive = try ZipArchive(zip.data)
      #expect(throws: PlatformToolsError.badArchive) {
        _ = try archive.contents(of: "platform-tools/adb")
      }
    }
  }

  @Test func rejectsADuplicateName() {
    #expect(throws: PlatformToolsError.badArchive) {
      var zip = TestZip()
      zip.add("platform-tools/adb", "first", mode: 0o100_755)
      zip.add("platform-tools/adb", "second", mode: 0o100_755)
      _ = try ZipArchive(zip.data)
    }
  }

  /// Google's names are ASCII; lookalikes of `.`, `/` and control characters are refused.
  @Test(arguments: [
    "platform-tools/\u{FF0E}\u{FF0E}/adb", "platform-tools\u{2215}adb", "adb\u{202E}", "C:/adb",
  ])
  func rejectsANameThatIsNotPlainASCII(name: String) {
    #expect(throws: PlatformToolsError.badArchive) {
      var zip = TestZip()
      zip.add(name, "x")
      _ = try ZipArchive(zip.data)
    }
  }

  /// An empty stored body cannot stand for a file the directory says has bytes.
  @Test func rejectsAnEmptyBodyForANonEmptyFile() throws {
    var zip = TestZip()
    zip.entries.append(.init(name: "platform-tools/adb", data: Data("adb".utf8)))
    var data = zip.data
    // The central directory says 3 bytes, stored: point its compressed size at nothing.
    let central = try #require(data.firstRange(of: Data([0x50, 0x4b, 0x01, 0x02])))
    data[central.lowerBound + 20] = 0
    let archive = try ZipArchive(data)
    #expect(throws: PlatformToolsError.badArchive) {
      _ = try archive.contents(of: "platform-tools/adb")
    }
  }

  @Test func rejectsAnEncryptedEntry() {
    #expect(throws: PlatformToolsError.self) {
      var zip = TestZip()
      zip.entries.append(.init(name: "platform-tools/adb", data: Data("adb".utf8), encrypted: true))
      _ = try ZipArchive(zip.data)
    }
  }

  @Test func rejectsATruncatedArchive() {
    var zip = TestZip()
    zip.add("platform-tools/adb", String(repeating: "adb ", count: 500))
    let data = zip.data
    for cut in [1, 22, data.count / 2, data.count - 30] {
      #expect(throws: PlatformToolsError.self, "cut \(cut)") {
        let archive = try ZipArchive(data.prefix(data.count - cut))
        _ = try archive.contents(of: "platform-tools/adb")
      }
    }
  }

  @Test func rejectsAChecksumMismatch() throws {
    var zip = TestZip()
    zip.entries.append(.init(name: "platform-tools/adb", data: Data("adb".utf8), crc: 1))
    let archive = try ZipArchive(zip.data)
    #expect(throws: PlatformToolsError.badArchive) {
      _ = try archive.contents(of: "platform-tools/adb")
    }
  }

  @Test func rejectsSomethingThatIsNotAZip() {
    #expect(throws: PlatformToolsError.badArchive) {
      _ = try ZipArchive(Data("not a zip".utf8))
    }
  }

  @Test func crc32MatchesTheStandardCheckValue() {
    #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
  }
}
