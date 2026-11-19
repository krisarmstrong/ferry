import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing
import os

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")

/// Saving and discarding a finished recording: the pull is bounded in size and in time, follows
/// the device's route now, and leaves an ejected device alone.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsSaveTests {
  let scratch: URL
  let journal: ToolJournal
  /// The route the device is served by now; `nil` once it is ejected.
  let route = OSAllocatedUnfairLock<String?>(initialState: "0123456789abcdef")

  init() throws {
    scratch = try TestScratch.folder("saves")
    journal = ToolJournal(store: scratch.appending(path: "journal.json"))
  }

  /// Tools whose device has a finished recording waiting.
  private func finished(_ fake: FakeToolDevice, limits: ADBTools.Limits = .init()) async throws
    -> ADBTools
  {
    let route = route
    let tools = ADBTools(
      device: fake, target: { _ in route.withLock { $0 } }, journal: journal, scratch: scratch,
      limits: limits)
    let recording = Task { try await tools.startRecording(device) }
    let deadline = ContinuousClock.now + .seconds(5)
    while await tools.recordingsRunning().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    await fake.recording.end()
    #expect(try await recording.value == .done)
    return tools
  }

  private func destination() throws -> (URL, FileHandle) {
    let url = scratch.appending(path: "capture-\(UUID().uuidString)")
    try Data().write(to: url)
    return (url, try FileHandle(forWritingTo: url))
  }

  /// The device is removed from the list, and its file from the device and the journal.
  private func expectGone(_ tools: ADBTools, _ fake: FakeToolDevice) async {
    #expect(await tools.recordingsRunning().isEmpty)
    #expect(await fake.removals.count == 1)
    #expect(await journal.paths(on: device).isEmpty)
  }

  @Test func anEndlessPullIsStoppedAtTheCapAndDeleted() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullBehaviour = .endless }
    var limits = ADBTools.Limits()
    limits.recordingSize = 64 * 1024
    let tools = try await finished(fake, limits: limits)
    let (url, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor)
        == .failed(.recordingTooLarge))
    #expect(try Data(contentsOf: url).isEmpty)
    await expectGone(tools, fake)
  }

  @Test func aRecordingDeclaredLargerThanTheCapIsRefused() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullBehaviour = .declares(5 << 30) }
    let tools = try await finished(fake)
    let (_, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor)
        == .failed(.recordingTooLarge))
    await expectGone(tools, fake)
  }

  /// A pull that stops arriving (a Wi-Fi roam, a busy link) is given up, but the video stays
  /// on the device and in the journal for another try.
  @Test func aPullThatStopsArrivingKeepsTheRecording() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullBehaviour = .stalls }
    var limits = ADBTools.Limits()
    limits.pullStall = .milliseconds(80)
    let tools = try await finished(fake, limits: limits)
    let (url, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor)
        == .failed(.recordingStalled))
    #expect(await tools.recordingsRunning().map(\.finished) == [true])
    #expect(await fake.removals.isEmpty)
    #expect(await journal.paths(on: device).count == 1)
    await fake.recording.set { $0.pullBehaviour = .normal }
    #expect(try await tools.saveRecording(device, into: handle.fileDescriptor) == .done)
    #expect(try Data(contentsOf: url) == FakeRecording.mp4)
    await expectGone(tools, fake)
  }

  /// A pull that completes as the watchdog gives up on it is a pull that completed.
  @Test func aPullThatFinishesAsTheWatchdogFiresIsSaved() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullBehaviour = .finishesLate(.milliseconds(300)) }
    var limits = ADBTools.Limits()
    limits.pullStall = .milliseconds(80)
    let tools = try await finished(fake, limits: limits)
    let (url, handle) = try destination()
    #expect(try await tools.saveRecording(device, into: handle.fileDescriptor) == .done)
    #expect(try Data(contentsOf: url) == FakeRecording.mp4)
    await expectGone(tools, fake)
  }

  /// No room on the Mac: the video stays on the device for another try.
  @Test func aRecordingTheMacHasNoRoomForIsKept() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullBehaviour = .declares(UInt64.max / 4) }
    var limits = ADBTools.Limits()
    limits.recordingSize = .max
    let tools = try await finished(fake, limits: limits)
    let (_, handle) = try destination()
    do {
      _ = try await tools.saveRecording(device, into: handle.fileDescriptor)
      Issue.record("saved with no room")
    } catch {
      guard case .macDiskFull = error else {
        Issue.record("unexpected \(error)")
        return
      }
    }
    #expect(await tools.recordingsRunning().map(\.finished) == [true])
    #expect(await fake.removals.isEmpty)
  }

  /// The app's cancel stops the pull, as the device breaking it off does: the video waits on the
  /// device for another try.
  @Test func aCancelledPullKeepsTheRecording() async throws {
    let fake = FakeToolDevice()
    let tools = try await finished(fake)
    let (_, handle) = try destination()
    let cancellation = RequestCancellation()
    cancellation.cancel()
    await #expect(throws: TransportError.cancelled) {
      _ = try await RequestCancellation.$current.withValue(cancellation) {
        try await tools.saveRecording(device, into: handle.fileDescriptor)
      }
    }
    #expect(await tools.recordingsRunning().map(\.finished) == [true])
    #expect(await fake.removals.isEmpty)
    #expect(try await tools.saveRecording(device, into: handle.fileDescriptor) == .done)
  }

  /// An ejected device is left alone: nothing is pulled or removed, and the video waits.
  @Test func anEjectedDeviceKeepsItsRecording() async throws {
    let fake = FakeToolDevice()
    let tools = try await finished(fake)
    route.withLock { $0 = nil }
    let (_, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor) == .failed(.notOverADB))
    #expect(await fake.recording.pulls.isEmpty)
    #expect(await tools.recordingsRunning().map(\.finished) == [true])
  }

  /// The pull follows the device's route now, not the one it was recorded over.
  @Test func thePullUsesTheRouteNow() async throws {
    let fake = FakeToolDevice()
    let tools = try await finished(fake)
    route.withLock { $0 = "10.0.0.5:5555" }
    let (_, handle) = try destination()
    #expect(try await tools.saveRecording(device, into: handle.fileDescriptor) == .done)
    #expect(await fake.recording.pulls == ["10.0.0.5:5555"])
    #expect(await fake.removals.count == 1)
  }

  @Test func discardDeletesAWaitingRecording() async throws {
    let fake = FakeToolDevice()
    let tools = try await finished(fake)
    #expect(try await tools.discardRecording(device) == .done)
    await expectGone(tools, fake)
    #expect(try await tools.discardRecording(device) == .failed(.notRecording))
  }

  /// An ejected device's recording is forgotten, and its file is swept at its next session.
  @Test func discardOnAnEjectedDeviceLeavesTheFileToTheSweep() async throws {
    let fake = FakeToolDevice()
    let tools = try await finished(fake)
    route.withLock { $0 = nil }
    #expect(try await tools.discardRecording(device) == .done)
    #expect(await tools.recordingsRunning().isEmpty)
    #expect(await fake.removals.isEmpty)
    await journal.sweep(device, serial: device.serial, using: fake)
    #expect(await fake.removals.count == 1)
  }

  @Test func aRunningRecordingIsNotDiscarded() async throws {
    let fake = FakeToolDevice()
    let tools = ADBTools(
      device: fake, target: { _ in "0123456789abcdef" }, journal: journal, scratch: scratch)
    let recording = Task { try await tools.startRecording(device) }
    let deadline = ContinuousClock.now + .seconds(5)
    while await tools.recordingsRunning().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await tools.discardRecording(device) == .failed(.recordingBusy))
    await fake.recording.end()
    _ = try await recording.value
  }
}
