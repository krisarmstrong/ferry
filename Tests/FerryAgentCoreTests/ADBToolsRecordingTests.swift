import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")
private let serial = "0123456789abcdef"
private let moment = Date(timeIntervalSince1970: 1_795_039_767)

/// Screen recordings as the agent runs them: one per device, stopped by Stop, by their time limit
/// or by Ferry when they outlive it, then waiting on the device until the app collects the video
/// into its file, after which the device's copy is removed.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsRecordingTests {
  let scratch: URL
  let journal: ToolJournal

  init() throws {
    scratch = try TestScratch.folder("recordings")
    journal = ToolJournal(store: scratch.appending(path: "journal.json"))
  }

  private func makeTools(_ fake: FakeToolDevice, limits: ADBTools.Limits = .init()) -> ADBTools {
    ADBTools(
      device: fake, target: { _ in serial }, journal: journal, scratch: scratch, now: { moment },
      limits: limits)
  }

  private func destination() throws -> (URL, FileHandle) {
    let url = scratch.appending(path: "capture-\(UUID().uuidString)")
    try Data().write(to: url)
    return (url, try FileHandle(forWritingTo: url))
  }

  /// Waits until the recording is under way, as the menu would show it.
  private func whenRecording(_ tools: ADBTools) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await tools.recordingsRunning().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func path(_ fake: FakeToolDevice) async throws -> String {
    try #require(await fake.recordingsStarted.first?.path)
  }

  @Test func stopEndsTheRecordingAndTheAppCollectsIt() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    #expect(
      await tools.recordingsRunning()
        == [ActiveRecording(device: device, started: moment, stopping: false)])
    #expect(try await tools.startRecording(device) == .failed(.alreadyRecording))
    #expect(try await tools.stopRecording(device) == .done)
    #expect(try await recording.value == .done)
    #expect(
      await tools.recordingsRunning()
        == [ActiveRecording(device: device, started: moment, stopping: true, finished: true)])
    let path = try await path(fake)
    #expect(await journal.paths(on: device) == [path])
    let (url, handle) = try destination()
    #expect(try await tools.saveRecording(device, into: handle.fileDescriptor) == .done)
    #expect(try Data(contentsOf: url) == FakeRecording.mp4)
    #expect(await fake.recording.interrupts == 1)
    #expect(await fake.removals == [path])
    #expect(await journal.paths(on: device).isEmpty)
    #expect(await tools.recordingsRunning().isEmpty)
  }

  @Test func stopOrSaveWithoutARecordingIsRefused() async throws {
    let tools = makeTools(FakeToolDevice())
    #expect(try await tools.stopRecording(device) == .failed(.notRecording))
    let (_, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor) == .failed(.notRecording))
  }

  /// A recording still running cannot be collected yet.
  @Test func aRunningRecordingIsNotCollected() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    let (url, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor)
        == .failed(.recordingBusy))
    #expect(try Data(contentsOf: url).isEmpty)
    await fake.recording.end()
    _ = try await recording.value
  }

  /// At its time limit screenrecord stops by itself; it waits, finished, with no Stop.
  @Test func aRecordingThatEndsByItselfWaitsToBeCollected() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    #expect(try await recording.value == .done)
    #expect(await tools.recordingsRunning().map(\.finished) == [true])
    #expect(await fake.recording.interrupts == 0)
  }

  /// One that outlives its limit is stopped by Ferry, and closed if SIGINT does not end it.
  @Test func aRecordingPastItsLimitIsStoppedThenClosed() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.endsOnInterrupt = false }
    var limits = ADBTools.Limits()
    limits.recording = .milliseconds(20)
    limits.grace = .zero
    limits.stopWait = .milliseconds(20)
    _ = try await makeTools(fake, limits: limits).startRecording(device)
    #expect(await fake.recording.interrupts == 1)
    #expect(await fake.recording.abandons == 1)
  }

  @Test func aRecordingThatDoesNotEndAfterStopIsClosed() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.endsOnInterrupt = false }
    var limits = ADBTools.Limits()
    limits.stopWait = .milliseconds(20)
    let tools = makeTools(fake, limits: limits)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    #expect(try await tools.stopRecording(device) == .done)
    _ = try await recording.value
    #expect(await fake.recording.abandons == 1)
  }

  /// A kill that never answers still ends in the connection being closed, so the device's slot
  /// is freed.
  @Test func aStopWhoseKillHangsStillClosesTheRecording() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.interruptHangs = true }
    var limits = ADBTools.Limits()
    limits.stopWait = .milliseconds(20)
    let tools = makeTools(fake, limits: limits)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    let stop = Task { try await tools.stopRecording(device) }
    _ = try await recording.value
    _ = try await stop.value
    #expect(await fake.recording.abandons == 1)
  }

  @Test func aRecordingWithNoVideoIsRefusedAndRemoved() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set {
      $0.outcome = .exited(status: 1, detail: "ERROR: unable to create video encoder")
      $0.pullFailure = .failed("open failed: No such file or directory")
    }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    _ = try await recording.value
    let (url, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor)
        == .failed(.recordingFailed("ERROR: unable to create video encoder")))
    #expect(try Data(contentsOf: url).isEmpty)
    #expect(await fake.removals.count == 1)
    #expect(await tools.recordingsRunning().isEmpty)
  }

  @Test func somethingOtherThanAVideoIsNotWritten() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.video = Data("garbage".utf8) }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    _ = try await recording.value
    let (url, handle) = try destination()
    #expect(
      try await tools.saveRecording(device, into: handle.fileDescriptor)
        == .failed(.recordingFailed("")))
    #expect(try Data(contentsOf: url).isEmpty)
  }

  /// The device went away while recording: disconnected, and its file stays journalled.
  @Test func aDeviceLostWhileRecordingIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.outcome = .lost(.connectionClosed) }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    await #expect(throws: TransportError.deviceDisconnected) { try await recording.value }
    #expect(await tools.recordingsRunning().isEmpty)
    #expect(await journal.paths(on: device) == [try await path(fake)])
  }

  /// A device that goes offline during the pull is disconnected, not a failed recording.
  @Test func aPullLostToTheDeviceIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullFailure = .failed("device offline") }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    _ = try await recording.value
    let (_, handle) = try destination()
    await #expect(throws: TransportError.deviceDisconnected) {
      try await tools.saveRecording(device, into: handle.fileDescriptor)
    }
    #expect(await fake.removals.isEmpty)
    #expect(await journal.paths(on: device) == [try await path(fake)])
    // The video is still on the device and listed, so it is collected once the device is back;
    // a session opening meanwhile does not sweep it.
    #expect(await tools.recordingsRunning().map(\.finished) == [true])
    await journal.sweep(device, serial: serial, using: fake)
    #expect(await fake.removals.isEmpty)
    await fake.recording.set { $0.pullFailure = nil }
    let (url, retry) = try destination()
    #expect(try await tools.saveRecording(device, into: retry.fileDescriptor) == .done)
    #expect(try Data(contentsOf: url) == FakeRecording.mp4)
  }
}
