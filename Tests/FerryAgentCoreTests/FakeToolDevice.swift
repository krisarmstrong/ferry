import ADBTransport
import DeviceKit
import Foundation

@testable import FerryAgentCore

/// A device's tools as `ADBTools` sees them, scripted, recording what Ferry asks of them.
actor FakeToolDevice: ADBToolDevice {
  static let png = ADBTools.pngMagic + Data(repeating: 9, count: 100)

  private(set) var installs: [(serial: String, contents: Data)] = []
  private(set) var screenshots: [String] = []
  private(set) var recordingsStarted: [String] = []
  var installResult = APKInstallResult.installed
  var failure: ADBError?
  var image = FakeToolDevice.png
  let recording: FakeRecording

  init(recording: FakeRecording = FakeRecording()) {
    self.recording = recording
  }

  func set(_ body: @Sendable (isolated FakeToolDevice) -> Void) { body(self) }

  func installAPK(_ file: FileHandle, serial: String, progress: ProgressHandler)
    async throws(ADBError) -> APKInstallResult
  {
    if let failure { throw failure }
    installs.append((serial, (try? file.readToEnd()) ?? Data()))
    return installResult
  }

  func screenshot(serial: String) async throws(ADBError) -> Data {
    if let failure { throw failure }
    screenshots.append(serial)
    return image
  }

  func recordScreen(serial: String) async throws(ADBError) -> any ScreenRecordingControl {
    if let failure { throw failure }
    recordingsStarted.append(serial)
    return recording
  }
}

/// A recording that runs until it is interrupted (or `end()`), then has `video` to pull.
actor FakeRecording: ScreenRecordingControl {
  static let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8) + Data(repeating: 1, count: 500)

  private(set) var interrupts = 0
  private(set) var abandons = 0
  private(set) var discards = 0
  /// Whether SIGINT stops it, as it stops `screenrecord`.
  var endsOnInterrupt = true
  /// Whether `kill` itself never answers.
  var interruptHangs = false
  var outcome = ADBScreenRecording.End.exited(status: 0, detail: "")
  var video = FakeRecording.mp4
  var pullFailure: ADBError?
  private var ended = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func set(_ body: @Sendable (isolated FakeRecording) -> Void) { body(self) }

  func finished() async -> ADBScreenRecording.End {
    if !ended { await withCheckedContinuation { waiters.append($0) } }
    return outcome
  }

  /// The recording ends by itself, as at its time limit.
  func end() {
    ended = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func interrupt() async throws(ADBError) {
    interrupts += 1
    if interruptHangs {
      // A wedged device: the kill never answers until the recording is closed.
      if !ended { await withCheckedContinuation { waiters.append($0) } }
      return
    }
    if endsOnInterrupt { end() }
  }

  func abandon() async {
    abandons += 1
    end()
  }

  func pull(into file: FileHandle, progress: ProgressHandler) async throws(ADBError) -> UInt64 {
    if let pullFailure { throw pullFailure }
    try? file.write(contentsOf: video)
    return UInt64(video.count)
  }

  func discard() async {
    discards += 1
  }
}

/// Minimal ZIP files, one stored (empty) entry per name, as `zip -0` writes them.
enum ZipFixture {
  static func archive(_ names: [String]) -> Data {
    var body = Data()
    var directory = Data()
    for name in names {
      let offset = UInt32(body.count)
      let bytes = Data(name.utf8)
      body += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
      body += le32(0) + le32(0) + le32(0) + le16(UInt16(bytes.count)) + le16(0) + bytes
      directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0)
      directory += le16(0) + le32(0) + le32(0) + le32(0) + le16(UInt16(bytes.count))
      directory += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + bytes
    }
    let end =
      le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(names.count))
      + le16(UInt16(names.count)) + le32(UInt32(directory.count)) + le32(UInt32(body.count))
      + le16(0)
    return body + directory + end
  }

  private static func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
  }

  private static func le32(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
  }
}
