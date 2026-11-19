import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryAgentCore

/// The journal of files the tools put on devices: what it keeps, what it reads back, and that a
/// sweep never touches a file a tool is still using.
@Suite(.timeLimit(.minutes(1)))
struct ToolJournalTests {
  let store: URL
  let device = DeviceID(serial: "0123456789abcdef")

  init() throws {
    store = try TestScratch.folder("journal").appending(path: "tool-files.json")
  }

  @Test func onlyToolPathsAreKeptOrReadBack() async throws {
    let apk = ADBDeviceTools.apkPath()
    let tampered = [device.serial: [apk, "/system/bin/sh", "/sdcard/DCIM/photo.jpg"], "": [apk]]
    try JSONEncoder().encode(tampered).write(to: store)
    let journal = ToolJournal(store: store)
    #expect(await journal.paths(on: device) == [apk])
    await journal.note("/data/local/tmp/other.apk", on: device)
    #expect(await journal.paths(on: device) == [apk])
  }

  @Test func anUnreadableJournalStartsEmpty() async throws {
    try Data("not json".utf8).write(to: store)
    #expect(await ToolJournal(store: store).paths(on: device).isEmpty)
  }

  @Test func theJournalIsPrivate() async throws {
    await ToolJournal(store: store).note(ADBDeviceTools.recordingPath(), on: device)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }

  /// A session that opens while a tool is pushing must not delete the tool's file.
  @Test func aSweepLeavesFilesInUse() async throws {
    let journal = ToolJournal(store: store)
    let busy = ADBDeviceTools.apkPath()
    let left = ADBDeviceTools.recordingPath()
    await journal.note(busy, on: device)
    await journal.note(left, on: device)
    await journal.release(left)
    let fake = FakeToolDevice()
    await journal.sweep(device, serial: device.serial, using: fake)
    #expect(await fake.removals == [left])
    #expect(await journal.paths(on: device) == [busy])
  }

  @Test func aFileThatStillCannotBeRemovedStays() async throws {
    let journal = ToolJournal(store: store)
    let left = ADBDeviceTools.apkPath()
    await journal.note(left, on: device)
    await journal.release(left)
    let fake = FakeToolDevice()
    await fake.set { $0.removes = false }
    await journal.sweep(device, serial: device.serial, using: fake)
    #expect(await journal.paths(on: device) == [left])
  }
}
