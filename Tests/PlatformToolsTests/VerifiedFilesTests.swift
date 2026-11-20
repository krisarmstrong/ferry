import Foundation
import Testing
import os

@testable import PlatformTools

/// A file that passed the signature check is not hashed again until it changes on disk.
final class VerifiedFilesTests: Sendable {
  private let folder: URL
  private let checks = OSAllocatedUnfairLock(initialState: 0)

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "ferry-verified-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  private func files(passing: Bool = true) -> VerifiedFiles {
    VerifiedFiles { [checks] _ throws(PlatformToolsError) in
      checks.withLock { $0 += 1 }
      if !passing { throw .notSigned }
    }
  }

  private func write(_ text: String, to name: String = "adb") throws -> URL {
    let file = folder.appending(path: name)
    try Data(text.utf8).write(to: file)
    return file
  }

  private var count: Int { checks.withLock { $0 } }

  @Test func anUnchangedFileIsCheckedOnce() throws {
    let adb = try write("adb")
    let files = files()
    try files.check(adb)
    try files.check(adb)
    #expect(count == 1)
  }

  @Test func aChangedTimeIsCheckedAgain() throws {
    let adb = try write("adb")
    let files = files()
    try files.check(adb)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: adb.path)
    try files.check(adb)
    #expect(count == 2)
  }

  @Test func aChangedSizeIsCheckedAgain() throws {
    let adb = try write("adb")
    let files = files()
    try files.check(adb)
    let date = try FileManager.default.attributesOfItem(atPath: adb.path)[.modificationDate]
    try Data("adb, longer".utf8).write(to: adb)
    try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: adb.path)
    try files.check(adb)
    #expect(count == 2)
  }

  /// A file swapped in under the same name is another inode.
  @Test func aReplacedFileIsCheckedAgain() throws {
    let adb = try write("adb")
    let files = files()
    try files.check(adb)
    let date = try FileManager.default.attributesOfItem(atPath: adb.path)[.modificationDate]
    let other = try write("bad", to: "other")
    try FileManager.default.setAttributes(
      [.modificationDate: date as Any], ofItemAtPath: other.path)
    _ = try FileManager.default.replaceItemAt(adb, withItemAt: other)
    try files.check(adb)
    #expect(count == 2)
  }

  @Test func aFailureIsNeverRemembered() throws {
    let adb = try write("adb")
    let files = files(passing: false)
    #expect(throws: PlatformToolsError.notSigned) { try files.check(adb) }
    #expect(throws: PlatformToolsError.notSigned) { try files.check(adb) }
    #expect(count == 2)
  }

  @Test func aMissingFileIsNotSigned() {
    #expect(throws: PlatformToolsError.notSigned) {
      try self.files().check(self.folder.appending(path: "missing"))
    }
    #expect(count == 0)
  }
}
