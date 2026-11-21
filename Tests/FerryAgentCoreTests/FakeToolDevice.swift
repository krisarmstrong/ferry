import ADBTransport
import DeviceKit
import Foundation
import Synchronization

@testable import FerryAgentCore

/// A device's tools as `ADBTools` sees them, scripted, recording what Ferry asks of them.
actor FakeToolDevice: ADBToolDevice {
  static let png = ADBTools.pngMagic + Data(repeating: 9, count: 100)

  struct Install: Equatable {
    let serial: String
    let path: String
    let contents: Data
  }

  private(set) var installs: [Install] = []
  /// Wakes, screenshots and recordings started, in order, as `<what> <serial>`.
  private(set) var order: [String] = []
  /// Whether the display came on when woken.
  var wakes = true
  private(set) var screenshots: [String] = []
  private(set) var recordingsStarted: [(serial: String, path: String)] = []
  /// Every `removeTemporary`, in order.
  private(set) var removals: [String] = []
  /// Whether removing works (the device is still there).
  var removes = true
  /// Runs as each tool file is created, to see what the journal holds then.
  var onCreate: (@Sendable (String) async -> Void)?
  var installResult = APKInstallResult.installed
  var failure: ADBError?
  /// The log the device streams; each `logcat` call opens the next.
  var logcats: [FakeLogcat] = []
  private(set) var logcatsOpened: [String] = []
  var info = AndroidDeviceInfo(
    model: "LinkRunner G2", androidVersion: "8.1.0", build: "OPM1", serial: "S", battery: nil,
    addresses: [], storage: nil)
  var forwardList: [PortForward] = []
  /// What removing a forward fails with, after the list showed it.
  var removeFailure: ADBError?
  /// Every forward request, as `add <local> <remote>` or `remove <local>`, with its serial.
  private(set) var forwardCalls: [String] = []
  var image = FakeToolDevice.png
  let recording: FakeRecording

  init(recording: FakeRecording = FakeRecording()) {
    self.recording = recording
  }

  func set(_ body: @Sendable (isolated FakeToolDevice) -> Void) { body(self) }

  func installAPK(_ file: FileHandle, to path: String, route: ADBRoute, progress: ProgressHandler)
    async throws(ADBError) -> APKInstallResult
  {
    await onCreate?(path)
    if let failure { throw failure }
    installs.append(
      Install(serial: route.serial, path: path, contents: (try? file.readToEnd()) ?? Data()))
    return installResult
  }

  func screenshot(route: ADBRoute) async throws(ADBError) -> Data {
    if let failure { throw failure }
    screenshots.append(route.serial)
    order.append("screenshot \(route.serial)")
    return image
  }

  func recordScreen(route: ADBRoute, to path: String) async throws(ADBError)
    -> any ScreenRecordingControl
  {
    await onCreate?(path)
    if let failure { throw failure }
    recordingsStarted.append((route.serial, path))
    order.append("record \(route.serial)")
    return recording
  }

  func wakeScreen(route: ADBRoute) async -> Bool {
    order.append("wake \(route.serial)")
    return wakes
  }

  func removeTemporary(_ path: String, route: ADBRoute) async -> Bool {
    removals.append(path)
    return removes
  }

  func logcat(route: ADBRoute) async throws(ADBError) -> any LogcatSource {
    if let failure { throw failure }
    logcatsOpened.append(route.serial)
    guard !logcats.isEmpty else { return FakeLogcat() }
    return logcats.removeFirst()
  }

  func deviceInfo(route: ADBRoute) async throws(ADBError) -> AndroidDeviceInfo {
    if let failure { throw failure }
    return info
  }

  func forwards(route: ADBRoute) async throws(ADBError) -> [PortForward] {
    if let failure { throw failure }
    return forwardList
  }

  func addForward(route: ADBRoute, _ forward: PortForward) async throws(ADBError) {
    if let failure { throw failure }
    forwardCalls.append("add \(route.serial) \(forward.local) \(forward.remote)")
    forwardList.append(forward)
  }

  func removeForward(route: ADBRoute, local: UInt16) async throws(ADBError) {
    if let failure { throw failure }
    if let removeFailure { throw removeFailure }
    forwardCalls.append("remove \(route.serial) \(local)")
    forwardList.removeAll { $0.local == local }
  }

  nonisolated func shellADB() -> ShellADB? { adbLocation.value }
  nonisolated let adbLocation = AdbLocation()
}

/// Where the fake finds adb, settable from a test without awaiting the device.
final class AdbLocation: Sendable {
  private let adb = Mutex<ShellADB?>(
    ShellADB(url: URL(fileURLWithPath: "/opt/homebrew/bin/adb"), runsServer: true))
  var value: ShellADB? { adb.withLock { $0 } }
  func set(_ url: URL?, runsServer: Bool = true) {
    adb.withLock { $0 = url.map { ShellADB(url: $0, runsServer: runsServer) } }
  }
}

/// A device's log as a test scripts it: lines go in with `send`, and end with `end()`, `fail`, or
/// the agent closing it.
actor FakeLogcat: LogcatSource {
  private var pending: [[Data]] = []
  private var waiter: CheckedContinuation<Void, Never>?
  private var ended = false
  private var failure: ADBError?
  private(set) var closed = false
  /// Who waits for the agent to have read every chunk sent.
  private var readWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Chunks sent that the agent has not yet read.
  var pendingCount: Int { pending.count }

  /// Returns once the agent has read every chunk sent so far, or the test is cancelled.
  func waitUntilRead() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if pending.isEmpty || Task.isCancelled {
          continuation.resume()
        } else {
          readWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.stopWaiting(id) }
    }
  }

  private func stopWaiting(_ id: UUID) {
    readWaiters.removeValue(forKey: id)?.resume()
  }

  func send(_ lines: [String]) {
    pending.append(lines.map { Data($0.utf8) })
    wake()
  }

  func sendRaw(_ lines: [Data]) {
    pending.append(lines)
    wake()
  }

  func end() {
    ended = true
    wake()
  }

  func fail(_ error: ADBError) {
    failure = error
    ended = true
    wake()
  }

  private func wake() {
    waiter?.resume()
    waiter = nil
  }

  func next() async throws(ADBError) -> [Data]? {
    while true {
      if !pending.isEmpty {
        let chunk = pending.removeFirst()
        if pending.isEmpty {
          for waiter in readWaiters.values { waiter.resume() }
          readWaiters = [:]
        }
        return chunk
      }
      if let failure { throw failure }
      if ended || closed { return nil }
      await withCheckedContinuation { waiter = $0 }
    }
  }

  nonisolated func close() {
    Task { await markClosed() }
  }

  private func markClosed() {
    closed = true
    wake()
  }
}

/// A recording that runs until it is interrupted (or `end()`), then has `video` to pull.
actor FakeRecording: ScreenRecordingControl {
  static let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8) + Data(repeating: 1, count: 500)

  private(set) var interrupts = 0
  private(set) var abandons = 0
  /// Whether SIGINT stops it, as it stops `screenrecord`.
  var endsOnInterrupt = true
  /// Whether `kill` itself never answers.
  var interruptHangs = false
  var outcome = ADBScreenRecording.End.exited(status: 0, detail: "")
  var video = FakeRecording.mp4
  var pullFailure: ADBError?
  /// The adb serial of each pull.
  private(set) var pulls: [String] = []
  /// How the pull behaves instead of sending `video`.
  var pullBehaviour = PullBehaviour.normal

  enum PullBehaviour: Sendable {
    case normal
    /// DATA forever, in chunks, until the progress handler stops it.
    case endless
    /// Reports a total of this many bytes, then sends `video`.
    case declares(UInt64)
    /// Sends nothing until cancelled.
    case stalls
    /// Sends `video`, then goes quiet for this long whatever happens, then finishes: a pull
    /// that completes just as the stall watchdog gives up on it.
    case finishesLate(Duration)
  }
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

  func pull(into file: FileHandle, route: ADBRoute, progress: ProgressHandler)
    async throws(ADBError) -> UInt64
  {
    pulls.append(route.serial)
    if let pullFailure { throw pullFailure }
    switch pullBehaviour {
    case .normal:
      try? file.write(contentsOf: video)
      guard progress(UInt64(video.count), UInt64(video.count)) else { throw .cancelled }
      return UInt64(video.count)
    case .endless:
      var sent: UInt64 = 0
      while true {
        let chunk = Data(repeating: 7, count: 512)
        try? file.write(contentsOf: chunk)
        sent += UInt64(chunk.count)
        // The device does not say how big it is.
        guard progress(sent, 0) else { throw .cancelled }
        await Task.yield()
      }
    case .declares(let total):
      guard progress(0, total) else { throw .cancelled }
      try? file.write(contentsOf: video)
      return UInt64(video.count)
    case .stalls:
      // Gives up only when cancelled, as a socket read does.
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
      throw .cancelled
    case .finishesLate(let quiet):
      try? file.write(contentsOf: video)
      // The last bytes are in flight: a cancel no longer stops them arriving.
      await Task.detached { try? await Task.sleep(for: quiet) }.value
      _ = progress(UInt64(video.count), UInt64(video.count))
      return UInt64(video.count)
    }
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
