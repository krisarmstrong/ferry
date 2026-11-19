import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// A recording the app could not save: it waits, with Choose Folder… and Discard, and is tried
/// again on its own only when a capture folder becomes writable.
@MainActor
struct AppModelRecordingTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")
  let finished = ActiveRecording(
    device: DeviceID(serial: "0123456789abcdef"),
    started: Date(timeIntervalSince1970: 1_795_039_767),
    stopping: false, finished: true)

  let client: FakeClient
  let services: FakeServices

  init() {
    client = FakeClient(log: log)
    services = FakeServices(log: log)
  }

  /// The device, served by `method`, has a finished recording waiting.
  private func setUp(method: ConnectionMethod = .usbADB) -> AppModel {
    client.setStatus(
      [device(id.serial, model: "LinkRunner-100G", .ready([]), method: method)],
      recordings: [finished])
    client.setTool(.done, writes: Data("....ftypmp42".utf8))
    return AppModel(client: client, services: services)
  }

  private func saves() -> Int { log.all.filter { $0.hasPrefix("saveRecording") }.count }

  /// Lets the collections a status started run.
  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  @Test func anUnsavableRecordingWaitsWithoutRetrying() async throws {
    let model = setUp()
    services.folders = [URL(filePath: "/nonexistent-ferry-\(UUID().uuidString)")]
    await model.refresh()
    await model.collectRecording(on: id)
    #expect(model.recordingUnsaved(on: id))
    #expect(model.actionError == DevicePresentation.message(for: .cannotSave))
    for _ in 0..<3 {
      await model.refresh()
      await settle()
    }
    #expect(saves() == 0)
    #expect(model.recording(on: id) != nil)
  }

  @Test func aFolderThatBecomesWritableIsTriedAgain() async throws {
    let model = setUp()
    services.folders = []
    await model.refresh()
    await model.collectRecording(on: id)
    #expect(model.recordingUnsaved(on: id))
    let folder = try TestScratch.folder("now-writable")
    services.folders = [folder]
    await model.refresh()
    let deadline = ContinuousClock.now + .seconds(5)
    while saves() == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(saves() == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
  }

  @Test func chooseFolderSavesWhereTheUserSays() async throws {
    let model = setUp()
    services.folders = []
    await model.refresh()
    await model.collectRecording(on: id)
    let folder = try TestScratch.folder("chosen")
    services.destination = folder.appending(path: "Field test.mp4")
    await model.chooseRecordingDestination(on: id)
    #expect(log.all.contains { $0.hasPrefix("chooseDestination Screen Recording LinkRunner-100G") })
    #expect(
      try Data(contentsOf: folder.appending(path: "Field test.mp4")) == Data("....ftypmp42".utf8))
    #expect(!model.recordingUnsaved(on: id))
    #expect(model.recording(on: id) == nil)
  }

  @Test func discardFreesTheDevice() async throws {
    let model = setUp()
    services.folders = []
    await model.refresh()
    await model.collectRecording(on: id)
    await model.discardRecording(on: id)
    #expect(log.all.contains("discardRecording \(id.serial)"))
    #expect(!model.recordingUnsaved(on: id))
    #expect(model.recording(on: id) == nil)
  }

  /// An ejected device's video waits on the device until it is served again.
  @Test func anEjectedDevicesRecordingIsNotCollected() async throws {
    let model = setUp(method: .usbFileTransfer)
    services.folders = [try TestScratch.folder("ejected")]
    await model.refresh()
    await settle()
    #expect(saves() == 0)
  }
}
