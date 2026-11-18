import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

struct LocalFileTests {
  let directory = TestScratch.root.appendingPathComponent(
    UUID().uuidString)

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func regularFileReportsItsSize() throws {
    defer { cleanUp() }
    let file = directory.appendingPathComponent("a")
    try Data(repeating: 1, count: 42).write(to: file)
    #expect(try LocalFile.regularFileSize(file) == 42)
  }

  @Test func emptyFileIsZeroNotAnError() throws {
    defer { cleanUp() }
    let file = directory.appendingPathComponent("empty")
    try Data().write(to: file)
    #expect(try LocalFile.regularFileSize(file) == 0)
  }

  @Test func symlinkReportsItsTargetsSize() throws {
    defer { cleanUp() }
    let file = directory.appendingPathComponent("target")
    try Data(repeating: 1, count: 300).write(to: file)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(try LocalFile.regularFileSize(link) == 300)
  }

  @Test func directoryIsAnError() throws {
    defer { cleanUp() }
    #expect(throws: TransportError.self) { try LocalFile.regularFileSize(directory) }
  }

  @Test func symlinkToDirectoryIsAnError() throws {
    defer { cleanUp() }
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: TestScratch.root)
    #expect(throws: TransportError.self) { try LocalFile.regularFileSize(link) }
  }

  @Test func missingFileIsAnError() throws {
    defer { cleanUp() }
    let missing = directory.appendingPathComponent("missing")
    #expect(throws: TransportError.self) { try LocalFile.regularFileSize(missing) }
  }

  @Test func danglingSymlinkIsAnError() throws {
    defer { cleanUp() }
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: directory.appendingPathComponent("gone"))
    #expect(throws: TransportError.self) { try LocalFile.regularFileSize(link) }
  }

  @Test func spaceCheckPassesForWhatFitsAndRefusesWhatDoesNot() throws {
    defer { cleanUp() }
    try LocalFile.requireSpace(1, at: directory)
    #expect {
      try LocalFile.requireSpace(UInt64.max, at: directory)
    } throws: { error in
      guard case TransportError.macDiskFull(UInt64.max, let free) = error else { return false }
      return free < UInt64.max
    }
  }
}
