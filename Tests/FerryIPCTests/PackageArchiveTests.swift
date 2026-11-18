import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FerryIPC

/// A package crosses between the agent and the extension as one stream; reading it never
/// writes outside the new folder it extracts into.
struct PackageArchiveTests {
  @Test func aTreeRoundTrips() throws {
    let folder = try TestScratch.folder("archive")
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: "Notes.rtfd")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Media/Deep"), withIntermediateDirectories: true)
    try Data("rtf".utf8).write(to: source.appending(path: "TXT.rtf"))
    try Data(count: 3 << 20).write(to: source.appending(path: "Media/big.bin"))
    try Data().write(to: source.appending(path: "Media/Deep/empty"))
    try FileManager.default.createSymbolicLink(
      at: source.appending(path: "link"), withDestinationURL: source.appending(path: "TXT.rtf"))
    let archive = folder.appending(path: "archive")
    #expect(FileManager.default.createFile(atPath: archive.path, contents: nil))
    let writer = try FileHandle(forWritingTo: archive)
    try PackageArchive.write(tree: source, to: writer)
    try writer.close()

    let out = folder.appending(path: "out.rtfd")
    let reader = try FileHandle(forReadingFrom: archive)
    try PackageArchive.extract(from: reader, to: out)
    try reader.close()

    #expect(try Data(contentsOf: out.appending(path: "TXT.rtf")) == Data("rtf".utf8))
    #expect(try Data(contentsOf: out.appending(path: "Media/big.bin")).count == 3 << 20)
    #expect(try Data(contentsOf: out.appending(path: "Media/Deep/empty")).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: out.appending(path: "link").path))
  }

  @Test(arguments: ["../escape", "/etc/passwd", "a/../../b", "a//b", "./a"])
  func aPathOutsideTheFolderIsRefused(_ path: String) throws {
    let folder = try TestScratch.folder("archive")
    defer { try? FileManager.default.removeItem(at: folder) }
    var data = Data("FERRYPKG1\n".utf8)
    data.append(2)
    withUnsafeBytes(of: UInt32(path.utf8.count).bigEndian) { data.append(contentsOf: $0) }
    data.append(Data(path.utf8))
    withUnsafeBytes(of: UInt64(1).bigEndian) { data.append(contentsOf: $0) }
    data.append(0x41)
    data.append(0)
    let archive = folder.appending(path: "evil")
    try data.write(to: archive)

    let reader = try FileHandle(forReadingFrom: archive)
    defer { try? reader.close() }
    #expect(throws: TransportError.self) {
      try PackageArchive.extract(from: reader, to: folder.appending(path: "out"))
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "escape").path))
  }

  @Test(arguments: [
    ("Notes.rtfd", true), ("Talk.key", true), ("Ferry.app", false), ("x.bundle", false),
    ("DCIM", false), ("a.txt", false),
  ])
  func documentPackagesAreRecognisedByName(name: String, isPackage: Bool) {
    #expect((Packages.documentType(named: name) != nil) == isPackage)
  }

  @Test func pathsInsideAPackageAreKnown() throws {
    #expect(Packages.isInsidePackage(try RemotePath("/Docs/Notes.rtfd/TXT.rtf")))
    #expect(Packages.isInsidePackage(try RemotePath("/Docs/Notes.rtfd/Media/a.png")))
    #expect(!Packages.isInsidePackage(try RemotePath("/Docs/Notes.rtfd")))
    #expect(!Packages.isInsidePackage(try RemotePath("/Docs/a.txt")))
    #expect(Packages.isPackageOrInside(try RemotePath("/Docs/Notes.rtfd")))
  }
}
