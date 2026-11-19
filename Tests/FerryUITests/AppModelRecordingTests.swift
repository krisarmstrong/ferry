import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
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
  let clock = TestClock()

  init() {
    client = FakeClient(log: log)
    services = FakeServices(log: log)
  }

  /// The device, served by `method` in its session `session`, has a finished recording waiting.
  private func serve(method: ConnectionMethod = .usbADB, session: UInt64 = 1) {
    client.setStatus(
      [device(id.serial, model: "LinkRunner-100G", .ready([]), method: method)],
      recordings: [finished], sessions: [id: session])
  }

  private func setUp(method: ConnectionMethod = .usbADB) -> AppModel {
    serve(method: method)
    client.setTool(.done, writes: Data("....ftypmp42".utf8))
    return AppModel(
      client: client, services: services, sleep: { try await Task.sleep(for: $0) },
      now: clock.now)
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
    clock.advance(.seconds(30))
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

  /// A save the device broke off (unplugged, say) is tried again once the device is reached
  /// again (a new session), even if no status saw it gone, not while it still looks served.
  @Test func aRecordingIsCollectedWhenItsDeviceComesBack() async throws {
    let model = setUp()
    let folder = try TestScratch.folder("device-back")
    services.folders = [folder]
    client.setTool(.failure(.deviceDisconnected))
    await model.refresh()
    try await waitForSaves(1)
    await settle()
    #expect(model.recordingUnsaved(on: id))
    await model.refresh()
    await settle()
    #expect(saves() == 1)

    // Replugged between two statuses: only its session number says so.
    serve(session: 2)
    client.setTool(.done, writes: Data("....ftypmp42".utf8))
    await model.refresh()
    try await waitForSaves(2)
    await settle()
    #expect(!model.recordingUnsaved(on: id))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
  }

  /// While a recording waits for a capture folder, the folders are checked (a file created and
  /// removed in each) at most every 30 s, not on every status.
  @Test func theFolderCheckIsThrottled() async throws {
    let model = setUp()
    services.folders = []
    await model.refresh()
    await model.collectRecording(on: id)
    #expect(model.recordingUnsaved(on: id))
    services.folders = [try TestScratch.folder("throttled")]
    clock.advance(.seconds(10))
    await model.refresh()
    // A check starts with the status that allows it; none did.
    #expect(!model.probingRecordings.contains(id))
    await settle()
    #expect(saves() == 0)

    clock.advance(.seconds(21))
    await model.refresh()
    try await waitForSaves(1)
  }

  /// A save the agent refused for another reason waits for the user, even across a reconnect.
  @Test func aRefusedSaveWaitsForTheUser() async throws {
    let model = setUp()
    services.folders = [try TestScratch.folder("refused")]
    client.setTool(.toolFailed(.recordingBusy))
    await model.refresh()
    try await waitForSaves(1)
    serve(session: 2)
    await model.refresh()
    await settle()
    #expect(saves() == 1)
    #expect(model.recordingUnsaved(on: id))
  }

  /// Discard the agent refused (the video is being saved) leaves the recording waiting.
  @Test func aRefusedDiscardKeepsTheRecordingWaiting() async throws {
    let model = setUp()
    services.folders = []
    await model.refresh()
    await model.collectRecording(on: id)
    try #require(model.recordingUnsaved(on: id))
    client.setDiscard(.toolFailed(.recordingBusy))
    await model.discardRecording(on: id)
    #expect(model.recordingUnsaved(on: id))
  }

  /// The writable-folder check creates a file and removes it, so it sees what a permission
  /// check alone can miss.
  @Test func theFolderCheckCreatesAndRemovesAFile() throws {
    let writable = try TestScratch.folder("takes-files")
    #expect(CaptureFiles.takesNewFiles(writable))
    #expect(try FileManager.default.contentsOfDirectory(atPath: writable.path).isEmpty)
    let readOnly = try TestScratch.folder("read-only")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
    }
    #expect(!CaptureFiles.takesNewFiles(readOnly))
    #expect(!CaptureFiles.takesNewFiles(writable.appending(path: "missing")))
  }

  private func waitForSaves(_ count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while saves() < count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(saves() == count)
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

/// A clock a test moves by hand.
final class TestClock: Sendable {
  private let instant = Mutex(ContinuousClock.now)

  var now: @Sendable () -> ContinuousClock.Instant {
    { self.instant.withLock { $0 } }
  }

  func advance(_ duration: Duration) {
    instant.withLock { $0 += duration }
  }
}
