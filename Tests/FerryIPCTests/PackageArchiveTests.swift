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

/// A tree past the budget is refused on either side, and a refused extraction leaves nothing.
struct PackageArchiveBudgetTests {
  /// `depth` nested folders, each holding a `size`-byte file.
  private func tree(depth: Int, size: Int, in folder: URL) throws -> URL {
    let root = folder.appending(path: "Deep.rtfd")
    var current = root
    for level in 0..<depth {
      current = current.appending(path: "level\(level)")
      try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
      try Data(count: size).write(to: current.appending(path: "file"))
    }
    return root
  }

  private func written(_ root: URL, budget: TreeBudget, in folder: URL) throws -> URL {
    let archive = folder.appending(path: "archive-\(UUID().uuidString)")
    #expect(FileManager.default.createFile(atPath: archive.path, contents: nil))
    let writer = try FileHandle(forWritingTo: archive)
    defer { try? writer.close() }
    try PackageArchive.write(tree: root, to: writer, budget: budget)
    return archive
  }

  @Test(arguments: [
    TreeBudget(maxDepth: 2, maxEntries: 100, maxBytes: 1 << 20),
    TreeBudget(maxDepth: 32, maxEntries: 5, maxBytes: 1 << 20),
    TreeBudget(maxDepth: 32, maxEntries: 100, maxBytes: 10),
  ])
  func writingPastTheBudgetIsRefused(budget: TreeBudget) throws {
    let folder = try TestScratch.folder("budget")
    defer { try? FileManager.default.removeItem(at: folder) }
    let root = try tree(depth: 4, size: 4, in: folder)

    #expect(throws: TransportError.packageTooLarge) {
      _ = try written(root, budget: budget, in: folder)
    }
  }

  @Test func extractingPastTheBudgetIsRefusedAndLeavesNothing() throws {
    let folder = try TestScratch.folder("budget")
    defer { try? FileManager.default.removeItem(at: folder) }
    let archive = try written(
      try tree(depth: 4, size: 4, in: folder), budget: .standard, in: folder)
    let reader = try FileHandle(forReadingFrom: archive)
    defer { try? reader.close() }
    let out = folder.appending(path: "out")

    #expect(throws: TransportError.packageTooLarge) {
      try PackageArchive.extract(
        from: reader, to: out, budget: TreeBudget(maxDepth: 2, maxEntries: 100, maxBytes: 1 << 20))
    }
    #expect(!FileManager.default.fileExists(atPath: out.path))
  }
}
