import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryUI

/// A capture saved when the app quit or crashed leaves a hidden file in the capture folder;
/// the next launch removes it once it is an hour old.
struct CaptureFilesSweepTests {
  @Test func oldCaptureLeftoversAreRemovedAndNothingElse() throws {
    let folder = try TestScratch.folder("capture-sweep")
    let old = folder.appending(path: CaptureFiles.temporaryPrefix + "old")
    let fresh = folder.appending(path: CaptureFiles.temporaryPrefix + "fresh")
    let other = folder.appending(path: "Screenshot.png")
    for file in [old, fresh, other] { try Data("x".utf8).write(to: file) }
    let twoHoursAgo = Date().addingTimeInterval(-7200)
    for file in [old, other] {
      try FileManager.default.setAttributes(
        [.modificationDate: twoHoursAgo], ofItemAtPath: file.path)
    }
    CaptureFiles.sweep([folder, folder])
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(left == [fresh.lastPathComponent, other.lastPathComponent].sorted())
  }
}
