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
    let scratch = ["ferry-transfer-\(UUID().uuidString)", SafeWriter.partialPrefix + "download"]
    let kept = ["notes.txt", "ferry-transferable.txt"]
    for name in scratch + kept {
      try Data("x".utf8).write(to: folder.appending(path: name))
    }

    FileTransfer.sweep(folder)

    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(left == kept.sorted())
  }
}
