import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryAgentCore

/// An agent that stopped mid-transfer leaves its scratch files behind; the next one removes them.
struct FileTransferSweepTests {
  @Test func sweepRemovesOnlyTheAgentsScratchFiles() throws {
    let folder = TestScratch.root.appending(
      path: "ferry-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let scratch = [
      "ferry-transfer-\(UUID().uuidString)", SafeWriter.partialPrefix + "download",
      "ferry-move-\(UUID().uuidString)",
    ]
    let kept = ["notes.txt", "ferry-transferable.txt"]
    for name in scratch + kept {
      try Data("x".utf8).write(to: folder.appending(path: name))
    }

    FileTransfer.sweep(folder)

    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(left == kept.sorted())
  }
}

/// A copy that cannot fit on the Mac fails before it starts, saying the Mac is full.
struct FileTransferSpaceTests {
  /// The source is sparse, so it takes no space; the copy goes to a watched test folder, so a
  /// check that let it through would stop the test process at `TestScratch.limit`.
  @Test func copyingInMoreThanTheMacHoldsFailsFirst() async throws {
    let folder = try TestScratch.folder("space")
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: "huge.bin")
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forUpdating: source)
    try handle.truncate(atOffset: 1 << 50)
    defer { try? handle.close() }

    await #expect {
      _ = try await FileTransfer.copyIn(handle.fileDescriptor, into: folder)
    } throws: { error in
      guard case TransportError.macDiskFull(let needed, _) = error else { return false }
      return needed == 1 << 50
    }
    #expect(TestScratch.allocatedBytes(at: folder) < 1 << 20)
  }
}

/// The guard counts what a test really wrote, not a sparse file's length.
struct TestScratchTests {
  @Test func realDataCountsAndSparseLengthDoesNot() throws {
    let folder = try TestScratch.folder("guard")
    defer { try? FileManager.default.removeItem(at: folder) }
    let sparse = folder.appending(path: "sparse.bin")
    #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
    let handle = try FileHandle(forUpdating: sparse)
    try handle.truncate(atOffset: 1 << 40)
    try handle.close()
    #expect(TestScratch.allocatedBytes(at: folder) < 1 << 20)

    try Data(count: 2 << 20).write(to: folder.appending(path: "real.bin"))
    #expect(TestScratch.allocatedBytes(at: folder) >= 2 << 20)
    #expect(TestScratch.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
  }
}
