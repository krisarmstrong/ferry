import DeviceKit
import Foundation
import Testing

@testable import FerryAgentCore

/// An agent that stopped mid-transfer leaves its scratch files behind; the next one removes them.
struct FileTransferSweepTests {
  @Test func sweepRemovesOnlyTheAgentsScratchFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
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
  @Test func copyingInMoreThanTheMacHoldsFailsFirst() async throws {
    let source = FileManager.default.temporaryDirectory.appending(
      path: "ferry-huge-\(UUID().uuidString)")
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: source) }
    // Sparse: far bigger than the volume, using no space.
    let handle = try FileHandle(forUpdating: source)
    try handle.truncate(atOffset: 1 << 50)
    defer { try? handle.close() }

    await #expect {
      _ = try await FileTransfer.copyIn(handle.fileDescriptor)
    } throws: { error in
      guard case TransportError.macDiskFull(let needed, _) = error else { return false }
      return needed == 1 << 50
    }
  }
}
