import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import os

let toolsLog = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBTools")

/// What `ADBTools` needs of a device on adb. `ADBDeviceTools` is the real one; tests script a
/// fake.
public protocol ADBToolDevice: Sendable {
  func installAPK(_ file: FileHandle, to path: String, route: ADBRoute, progress: ProgressHandler)
    async throws(ADBError) -> APKInstallResult
  func screenshot(route: ADBRoute) async throws(ADBError) -> Data
  func recordScreen(route: ADBRoute, to path: String) async throws(ADBError)
    -> any ScreenRecordingControl
  func removeTemporary(_ path: String, route: ADBRoute) async -> Bool
  /// Turns the display on, waiting a short while for it; whether it came on. Never throws: a
  /// capture goes ahead either way.
  func wakeScreen(route: ADBRoute) async -> Bool
  func logcat(route: ADBRoute) async throws(ADBError) -> any LogcatSource
  func deviceInfo(route: ADBRoute) async throws(ADBError) -> AndroidDeviceInfo
  func forwards(route: ADBRoute) async throws(ADBError) -> [PortForward]
  func addForward(route: ADBRoute, _ forward: PortForward) async throws(ADBError)
  func removeForward(route: ADBRoute, local: UInt16) async throws(ADBError)
  /// The `adb` a shell in Terminal runs, if there is one (see `ADBDeviceTools.shellADB()`).
  func shellADB() -> ShellADB?
}

/// A device's log as lines of bytes (see `ADBLogcat`).
public protocol LogcatSource: Sendable {
  /// The next lines; `nil` once the device ended the log; throws when it was lost.
  func next() async throws(ADBError) -> [Data]?
  /// Ends the log: a read waiting for more fails or returns `nil`.
  func close()
}

extension ADBLogcat: LogcatSource {}

/// A screen recording running on a device (see `ADBScreenRecording`).
public protocol ScreenRecordingControl: Sendable {
  func finished() async -> ADBScreenRecording.End
  func interrupt() async throws(ADBError)
  func abandon() async
  /// Copies the recording into `file` over `route`, the route the device is served by now.
  func pull(into file: FileHandle, route: ADBRoute, progress: ProgressHandler)
    async throws(ADBError) -> UInt64
}

extension ADBScreenRecording: ScreenRecordingControl {}

extension ADBDeviceTools: ADBToolDevice {
  public func recordScreen(route: ADBRoute, to path: String) async throws(ADBError)
    -> any ScreenRecordingControl
  {
    try await startRecording(route: route, to: path)
  }

  public func logcat(route: ADBRoute) async throws(ADBError) -> any LogcatSource {
    let log: ADBLogcat = try await logcat(route: route)
    return log
  }
}

/// The ADB tools: install an APK, take a screenshot, record the screen. Only a device the hub
/// serves over ADB (USB or the network) can use them, by the route its session uses.
///
/// The agent never opens a file on the Mac a client named, and never touches the user's folders:
/// the app creates each screenshot or recording file in the device's capture folder and sends it as a
/// writable descriptor, as `.fetch` does. The agent checks what the device sent in its own
/// scratch folder first (a PNG, an MP4), so the client's file receives only a whole, checked
/// capture. An APK arrives as a readable descriptor, is copied into the scratch folder, and is
/// checked to be an Android app there before anything reaches the device.
///
/// Files put on the device (the APK on its way to pm, the recording until it is collected) are
/// noted in the `ToolJournal` before they exist and dropped once removed; one that could not be
/// removed is swept the next time a session for the device opens.
///
/// A recording runs until Stop, its time limit or the process ending; `.startRecording` answers
/// then, and the recording waits on the device, listed as finished, until the app collects it
/// with `.saveRecording`, even after the app was relaunched.
public actor ADBTools {
  /// A log stream running for a device, ended by `stop()`, or by `routeLost()` when the device is
  /// no longer served by the route it began on.
  final class LogcatRun: Sendable {
    let id: UUID
    let source: any LogcatSource
    private let state = Mutex((stopped: false, routeLost: false))

    init(id: UUID, source: any LogcatSource) {
      self.id = id
      self.source = source
    }

    var isStopped: Bool { state.withLock { $0.stopped } }
    var isRouteLost: Bool { state.withLock { $0.routeLost } }

    func stop() {
      state.withLock { $0.stopped = true }
      source.close()
    }

    func routeLost() {
      state.withLock { $0.routeLost = true }
      source.close()
    }
  }

  public struct Limits: Sendable {
    /// No APK can be larger: its ZIP offsets are 32-bit.
    public var apkSize: UInt64 = 4 << 30
    /// How long a recording may run: `screenrecord`'s own limit, then `grace` before Ferry stops
    /// it itself.
    public var recording = ADBDeviceTools.recordingLimit
    public var grace = Duration.seconds(10)
    /// How long a recording may take to finish after SIGINT before its connection is closed.
    public var stopWait = Duration.seconds(15)
    /// The largest recording pulled (see `PullWatch`).
    public var recordingSize: UInt64 = 1 << 30
    /// How long a pull may go without data before it is given up.
    public var pullStall = Duration.seconds(30)
    /// The log queue between the device and the client keeps this many of the newest lines and
    /// bytes; older ones are dropped and counted.
    public var logQueueLines = 20_000
    public var logQueueBytes = 8 << 20
    /// A batch sent to the client holds at most this many lines and bytes (a line past the byte
    /// limit still goes alone), so no message is large.
    public var logBatchLines = 500
    public var logBatchBytes = 256 << 10
    /// The least time between two batches, so a busy log is sent in a few large batches rather
    /// than many small ones.
    public var logInterval = Duration.milliseconds(100)
    /// How often a log stream checks that its device is still served by its route.
    public var routeWatch = Duration.milliseconds(250)

    public init() {}
  }

  /// How a tool request ended, short of a lost device.
  public enum Outcome: Sendable, Equatable {
    case done
    case failed(ToolFailure)

    var response: AgentResponse {
      switch self {
      case .done: .done
      case .failed(let failure): .toolFailed(failure)
      }
    }
  }

  struct Recording {
    let token = UUID()
    let started: Date
    let path = ADBDeviceTools.recordingPath()
    var route: ADBRoute?
    var stopping = false
    var control: (any ScreenRecordingControl)?
    /// How it ended; `nil` while it runs.
    var end: ADBScreenRecording.End?
    var collecting = false
  }

  let device: any ADBToolDevice
  /// The route the tools use for a device: only a ready device served over ADB has one.
  let target: @Sendable (DeviceID) async -> ADBRoute?
  let journal: ToolJournal
  let scratch: URL
  let now: @Sendable () -> Date
  let limits: Limits
  /// What the pause between log batches is measured on.
  let clock: any Clock<Duration>
  var recordings: [DeviceID: Recording] = [:]
  var logcats: [DeviceID: LogcatRun] = [:]
  /// Streams a stop came for before they were up.
  var pendingStops: Set<UUID> = []

  public init(
    device: any ADBToolDevice, target: @escaping @Sendable (DeviceID) async -> ADBRoute?,
    journal: ToolJournal, scratch: URL = FileManager.default.temporaryDirectory,
    now: @escaping @Sendable () -> Date = Date.init, limits: Limits = Limits()
  ) {
    self.init(
      device: device, target: target, journal: journal, scratch: scratch, now: now,
      limits: limits, clock: ContinuousClock())
  }

  init(
    device: any ADBToolDevice, target: @escaping @Sendable (DeviceID) async -> ADBRoute?,
    journal: ToolJournal, scratch: URL, now: @escaping @Sendable () -> Date, limits: Limits,
    clock: any Clock<Duration>
  ) {
    self.clock = clock
    self.device = device
    self.target = target
    self.journal = journal
    self.scratch = scratch
    self.now = now
    self.limits = limits
  }

  /// The tools' route for `id`: `session`, the route its open session uses, for a ready
  /// device served over ADB only. The tools follow the session, not the latest scan: a network
  /// route the serving check stopped serving (its device got a Finder location after a terminal
  /// `adb connect`) still carries the files until that session ends, and so the tools too.
  public static func target(
    for id: DeviceID, devices: [AttachedDevice], session: ADBRoute?
  ) -> ADBRoute? {
    guard let device = devices.first(where: { $0.id == id }), case .ready = device.state,
      [.usbADB, .wifiADB].contains(device.method)
    else { return nil }
    return session
  }

  // MARK: APK

  /// Installs the APK in `source`, a readable descriptor from the client.
  public func installAPK(_ source: Int32, on id: DeviceID, progress: ProgressHandler)
    async throws(TransportError) -> Outcome
  {
    guard let route = await target(id) else { return .failed(.notOverADB) }
    guard try Self.size(of: source) <= limits.apkSize else { return .failed(.apkTooLarge) }
    // The source may grow after it was measured: the copy stops at the cap.
    guard let copy = try await FileTransfer.copyIn(source, into: scratch, atMost: limits.apkSize)
    else { return .failed(.apkTooLarge) }
    defer { FileTransfer.remove(copy) }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: copy)
    } catch {
      throw .io("cannot open the app: \(error.localizedDescription)")
    }
    defer { try? handle.close() }
    guard APKCheck.isAPK(at: copy) else { return .failed(.notAnAPK) }
    let path = ADBDeviceTools.apkPath()
    await journal.note(path, on: id)
    let result: Result<APKInstallResult, ADBError>
    do throws(ADBError) {
      result = .success(
        try await device.installAPK(handle, to: path, route: route, progress: progress))
    } catch {
      result = .failure(error)
    }
    await removeFromDevice(path, of: id, route: route)
    switch result {
    case .success(.installed): return .done
    case .success(.failed(let reason)): return .failed(.installFailed(reason))
    case .failure(let error): throw Self.transportError(error)
    }
  }

  // MARK: Screenshot

  /// Streams a screenshot into `target`, a writable descriptor from the client.
  public func screenshot(_ id: DeviceID, into file: Int32) async throws(TransportError) -> Outcome {
    try FileTransfer.requireRegular(file)
    guard let route = await target(id) else { return .failed(.notOverADB) }
    // A unit whose display is off captures black.
    _ = await device.wakeScreen(route: route)
    let image: Data
    do throws(ADBError) {
      image = try await device.screenshot(route: route)
    } catch {
      throw Self.transportError(error)
    }
    guard let png = Self.png(in: image) else { return .failed(.noImage) }
    let staged = FileTransfer.scratchURL(in: scratch)
    defer { FileTransfer.remove(staged) }
    do {
      try png.write(to: staged, options: .withoutOverwriting)
    } catch {
      throw .io("cannot stage the screenshot: \(error.localizedDescription)")
    }
    try await FileTransfer.copyOut(staged, to: file)
    return .done
  }

  static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  /// adbd's `exec:` carries stderr with stdout, so a warning can come before the image.
  static let pngSearch = 4096

  /// The PNG in what `screencap` sent, without any text before its signature; `nil` if no
  /// signature starts within the first 4 KB.
  static func png(in output: Data) -> Data? {
    guard let found = output.prefix(pngSearch + pngMagic.count).firstRange(of: pngMagic) else {
      return nil
    }
    return output[found.lowerBound...]
  }

  // MARK: Plumbing

  /// Removes a tool's file from the device and drops it from the journal once it is gone; one
  /// that stays is swept when the device's next session opens.
  func removeFromDevice(_ path: String, of id: DeviceID, route: ADBRoute) async {
    if await device.removeTemporary(path, route: route) {
      await journal.removed(path, on: id)
    } else {
      await journal.release(path)
    }
  }

  static func size(of descriptor: Int32) throws(TransportError) -> UInt64 {
    try FileTransfer.requireRegular(descriptor)
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw .io("cannot inspect the file") }
    return UInt64(clamping: info.st_size)
  }

  /// A device or server that went away is a disconnected device, as for files; adb's other
  /// failures carry its words.
  static func transportError(_ error: ADBError) -> TransportError {
    switch error {
    case .deviceGone, .connectionClosed, .serverUnavailable, .adbNotInstalled:
      .deviceDisconnected
    case .cancelled:
      .cancelled
    case .failed(let message)
    where message.contains("offline") || message.contains("unauthorized"):
      .deviceDisconnected
    case .failed(let message), .protocolViolation(let message), .invalidArgument(let message):
      .io(message)
    }
  }
}
