import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import os

let toolsLog = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBTools")

/// What `ADBTools` needs of a device on adb. `ADBDeviceTools` is the real one; tests script a
/// fake.
public protocol ADBToolDevice: Sendable {
  func installAPK(_ file: FileHandle, to path: String, serial: String, progress: ProgressHandler)
    async throws(ADBError) -> APKInstallResult
  func screenshot(serial: String) async throws(ADBError) -> Data
  func recordScreen(serial: String, to path: String) async throws(ADBError)
    -> any ScreenRecordingControl
  func removeTemporary(_ path: String, serial: String) async -> Bool
}

/// A screen recording running on a device (see `ADBScreenRecording`).
public protocol ScreenRecordingControl: Sendable {
  func finished() async -> ADBScreenRecording.End
  func interrupt() async throws(ADBError)
  func abandon() async
  /// Copies the recording into `file` over `serial`, the route the device is served by now.
  func pull(into file: FileHandle, serial: String, progress: ProgressHandler)
    async throws(ADBError) -> UInt64
}

extension ADBScreenRecording: ScreenRecordingControl {}

extension ADBDeviceTools: ADBToolDevice {
  public func recordScreen(serial: String, to path: String) async throws(ADBError)
    -> any ScreenRecordingControl
  {
    try await startRecording(serial: serial, to: path)
  }
}

/// The ADB tools: install an APK, take a screenshot, record the screen. Only a device the hub
/// serves over ADB (USB or the network) can use them, by the route its session uses.
///
/// The agent never opens a file on the Mac a client named, and never touches the user's folders:
/// the app creates each screenshot or recording file where macOS saves its own and sends it as a
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
    var serial: String?
    var stopping = false
    var control: (any ScreenRecordingControl)?
    /// How it ended; `nil` while it runs.
    var end: ADBScreenRecording.End?
    var collecting = false
  }

  let device: any ADBToolDevice
  /// The adb serial the tools use for a device: only a ready device served over ADB has one.
  let target: @Sendable (DeviceID) async -> String?
  let journal: ToolJournal
  let scratch: URL
  let now: @Sendable () -> Date
  let limits: Limits
  var recordings: [DeviceID: Recording] = [:]

  public init(
    device: any ADBToolDevice, target: @escaping @Sendable (DeviceID) async -> String?,
    journal: ToolJournal, scratch: URL = FileManager.default.temporaryDirectory,
    now: @escaping @Sendable () -> Date = Date.init, limits: Limits = Limits()
  ) {
    self.device = device
    self.target = target
    self.journal = journal
    self.scratch = scratch
    self.now = now
    self.limits = limits
  }

  /// The tools' adb serial for `id`: the route its session uses, for a ready device served over
  /// ADB only.
  public static func target(
    for id: DeviceID, devices: [AttachedDevice], routes: ADBRoutes?
  ) -> String? {
    guard let device = devices.first(where: { $0.id == id }), case .ready = device.state,
      [.usbADB, .wifiADB].contains(device.method)
    else { return nil }
    return routes?.preferred
  }

  // MARK: APK

  /// Installs the APK in `source`, a readable descriptor from the client.
  public func installAPK(_ source: Int32, on id: DeviceID, progress: ProgressHandler)
    async throws(TransportError) -> Outcome
  {
    guard let serial = await target(id) else { return .failed(.notOverADB) }
    guard try Self.size(of: source) <= limits.apkSize else { return .failed(.apkTooLarge) }
    let copy = try await FileTransfer.copyIn(source, into: scratch)
    defer { FileTransfer.remove(copy) }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: copy)
    } catch {
      throw .io("cannot open the app: \(error.localizedDescription)")
    }
    defer { try? handle.close() }
    // The source may have grown after it was measured.
    guard try Self.size(of: handle.fileDescriptor) <= limits.apkSize else {
      return .failed(.apkTooLarge)
    }
    guard APKCheck.isAPK(at: copy) else { return .failed(.notAnAPK) }
    let path = ADBDeviceTools.apkPath()
    await journal.note(path, on: id)
    let result: Result<APKInstallResult, ADBError>
    do throws(ADBError) {
      result = .success(
        try await device.installAPK(handle, to: path, serial: serial, progress: progress))
    } catch {
      result = .failure(error)
    }
    await removeFromDevice(path, of: id, serial: serial)
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
    guard let serial = await target(id) else { return .failed(.notOverADB) }
    let image: Data
    do throws(ADBError) {
      image = try await device.screenshot(serial: serial)
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
  func removeFromDevice(_ path: String, of id: DeviceID, serial: String) async {
    if await device.removeTemporary(path, serial: serial) {
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
