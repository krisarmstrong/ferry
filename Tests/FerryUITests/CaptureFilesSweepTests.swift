import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryUI

/// A capture saved when the app quit or crashed leaves a hidden file in the capture folder;
/// the next save into that folder removes it once it is an hour old.
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

  /// Launch touches no capture folder: Documents is protected, and asking for it would put a
  /// prompt ahead of the menu.
  @MainActor @Test func launchListsNoCaptureFolder() async {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    await model.launch()
    #expect(!log.all.contains("captureFolders"))
  }

  /// A save sweeps the folder it saves into, which it has access to by then.
  @MainActor @Test func aSaveSweepsItsFolder() async throws {
    let root = try TestScratch.folder("save-sweep")
    let folder = CaptureFiles.folder(
      CaptureFiles.screenshotsFolder, device: "LinkRunner-100G", in: root)
    CaptureFiles.make(folder)
    let stale = folder.appending(path: CaptureFiles.temporaryPrefix + "stale")
    try Data("x".utf8).write(to: stale)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)
    let log = CallLog()
    let client = FakeClient(log: log)
    let unit = device("0123456789abcdef", model: "LinkRunner-100G", .ready([]), method: .usbADB)
    client.setStatus([unit])
    client.setTool(.done, writes: Data([0x89, 0x50, 0x4E, 0x47]))
    let services = FakeServices(log: log)
    services.folders = [root]
    let model = AppModel(client: client, services: services)
    await model.refresh()
    await model.takeScreenshot(on: unit.id)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(saved.count == 1 && saved.first?.hasPrefix("Screenshot") == true)
  }
}
