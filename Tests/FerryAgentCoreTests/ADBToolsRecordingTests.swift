import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")
private let target = ADBTools.Target(serial: "0123456789abcdef", model: "LinkRunner-100G")
/// 2026-11-18 22:09:27 UTC.
private let moment = Date(timeIntervalSince1970: 1_795_039_767)

/// Screen recordings as the agent runs them: one per device, stopped by Stop, by their time
/// limit or by Ferry when they outlive it, saved where screenshots go and removed from the device.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsRecordingTests {
  let folder: URL
  let desktop: URL

  init() throws {
    folder = try TestScratch.folder("recordings")
    desktop = try TestScratch.folder("desktop")
  }

  private func makeTools(_ fake: FakeToolDevice, limits: ADBTools.Limits = .init()) -> ADBTools {
    let shots = folder
    return ADBTools(
      device: fake, target: { _ in target }, folder: { shots }, desktop: desktop,
      scratch: folder, now: { moment }, limits: limits)
  }

  private func names(_ url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
  }

  /// Waits until the recording is under way, as the menu would show it.
  private func whenRecording(_ tools: ADBTools) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await tools.recordingsRunning().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func stopSavesTheRecordingAndRemovesItFromTheDevice() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    #expect(
      await tools.recordingsRunning()
        == [ActiveRecording(device: device, started: moment, stopping: false)])
    #expect(try await tools.startRecording(device) == .failed(.alreadyRecording))
    #expect(try await tools.stopRecording(device) == .done)
    let base = CaptureFiles.baseName(.recording, model: "LinkRunner-100G", at: moment)
    #expect(try await recording.value == .saved(folder.appending(path: base + ".mp4")))
    #expect(try Data(contentsOf: folder.appending(path: base + ".mp4")) == FakeRecording.mp4)
    #expect(await fake.recording.interrupts == 1)
    #expect(await fake.recording.discards == 1)
    #expect(await tools.recordingsRunning().isEmpty)
  }

  @Test func stopWithoutARecordingIsRefused() async throws {
    #expect(try await makeTools(FakeToolDevice()).stopRecording(device) == .failed(.notRecording))
  }

  /// At its time limit screenrecord stops by itself; the file is saved with no Stop.
  @Test func aRecordingThatEndsByItselfIsSaved() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    guard case .saved = try await recording.value else {
      Issue.record("not saved")
      return
    }
    #expect(await fake.recording.interrupts == 0)
    #expect(await fake.recording.discards == 1)
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
    #expect(await tools.recordingsRunning().isEmpty)
  }

  @Test func aRecordingWithNoVideoLeavesNoFile() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set {
      $0.outcome = .exited(status: 1, detail: "ERROR: unable to create video encoder")
      $0.pullFailure = .failed("open failed: No such file or directory")
    }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    #expect(
      try await recording.value
        == .failed(.recordingFailed("ERROR: unable to create video encoder")))
    #expect(try names(folder).isEmpty)
    #expect(await fake.recording.discards == 1)
  }

  @Test func somethingOtherThanAVideoIsNotSaved() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.video = Data("garbage".utf8) }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    #expect(try await recording.value == .failed(.recordingFailed("")))
    #expect(try names(folder).isEmpty)
  }

  @Test func aDeviceLostWhileRecordingIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set {
      $0.outcome = .lost(.connectionClosed)
      $0.pullFailure = .deviceGone("0123456789abcdef")
    }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    await #expect(throws: TransportError.deviceDisconnected) { try await recording.value }
    #expect(try names(folder).isEmpty)
    #expect(await tools.recordingsRunning().isEmpty)
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
    #expect(await tools.recordingsRunning().isEmpty)
  }

  /// A device that goes offline during the pull is disconnected, not a failed recording.
  @Test func aPullLostToTheDeviceIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.recording.set { $0.pullFailure = .failed("device offline") }
    let tools = makeTools(fake)
    let recording = Task { try await tools.startRecording(device) }
    try await whenRecording(tools)
    await fake.recording.end()
    await #expect(throws: TransportError.deviceDisconnected) { try await recording.value }
  }
}
