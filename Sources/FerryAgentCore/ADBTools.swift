import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBTools")

/// What `ADBTools` needs of a device on adb. `ADBDeviceTools` is the real one; tests script a
/// fake.
public protocol ADBToolDevice: Sendable {
  func installAPK(_ file: FileHandle, serial: String, progress: ProgressHandler)
    async throws(ADBError) -> APKInstallResult
  func screenshot(serial: String) async throws(ADBError) -> Data
  func recordScreen(serial: String) async throws(ADBError) -> any ScreenRecordingControl
}

/// A screen recording running on a device (see `ADBScreenRecording`).
public protocol ScreenRecordingControl: Sendable {
  func finished() async -> ADBScreenRecording.End
  func interrupt() async throws(ADBError)
  func abandon() async
  func pull(into file: FileHandle, progress: ProgressHandler) async throws(ADBError) -> UInt64
  func discard() async
}

extension ADBScreenRecording: ScreenRecordingControl {}

extension ADBDeviceTools: ADBToolDevice {
  public func recordScreen(serial: String) async throws(ADBError) -> any ScreenRecordingControl {
    try await startRecording(serial: serial)
  }
}

/// The ADB tools: install an APK, take a screenshot, record the screen. Only a device the hub
/// serves over ADB (USB or the network) can use them, by the route its session uses.
///
/// The agent writes the screenshots and recordings itself, where macOS saves its own (see
/// `CaptureFiles`): it holds the device's stream, and a recording that reaches its time limit
/// is saved with no request waiting for it, even after the menu has quit. The app is told where
/// the file is only to show it in Finder; no path ever goes from the app to the agent.
///
/// An APK arrives as a descriptor, is copied into the agent's scratch folder, and is checked to
/// be an Android app there before anything reaches the device.
public actor ADBTools {
  /// The adb route the tools use for a device, and the model the file names carry.
  public struct Target: Sendable, Equatable {
    public let serial: String
    public let model: String

    public init(serial: String, model: String) {
      self.serial = serial
      self.model = model
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

    public init() {}
  }

  /// How a tool request ended, short of a lost device.
  public enum Outcome: Sendable, Equatable {
    case done
    case saved(URL)
    case failed(ToolFailure)

    var response: AgentResponse {
      switch self {
      case .done: .done
      case .saved(let url): .saved(url)
      case .failed(let failure): .toolFailed(failure)
      }
    }
  }

  private struct Recording {
    let token = UUID()
    let started: Date
    var stopping = false
    var control: (any ScreenRecordingControl)?
  }

  private let device: any ADBToolDevice
  private let target: @Sendable (DeviceID) async -> Target?
  let folder: @Sendable () -> URL
  let desktop: URL
  private let scratch: URL
  private let now: @Sendable () -> Date
  private let limits: Limits
  private var recordings: [DeviceID: Recording] = [:]

  public init(
    device: any ADBToolDevice, target: @escaping @Sendable (DeviceID) async -> Target?,
    folder: (@Sendable () -> URL)? = nil, desktop: URL? = nil,
    scratch: URL = FileManager.default.temporaryDirectory,
    now: @escaping @Sendable () -> Date = Date.init, limits: Limits = Limits()
  ) {
    self.device = device
    self.target = target
    self.folder = folder ?? { CaptureFiles.current() }
    self.desktop = desktop ?? CaptureFiles.desktop()
    self.scratch = scratch
    self.now = now
    self.limits = limits
  }

  /// The tools' route for `id`: only a ready device served over ADB has one.
  public static func target(
    for id: DeviceID, devices: [AttachedDevice], routes: ADBRoutes?
  ) -> Target? {
    guard let device = devices.first(where: { $0.id == id }), case .ready = device.state,
      device.method != .usbFileTransfer, let serial = routes?.preferred
    else { return nil }
    return Target(serial: serial, model: device.info.model)
  }

  public func recordingsRunning() -> [ActiveRecording] {
    recordings.map {
      ActiveRecording(device: $0.key, started: $0.value.started, stopping: $0.value.stopping)
    }
    .sorted { $0.started < $1.started }
  }

  // MARK: APK

  /// Installs the APK in `source`, a readable descriptor from the client.
  public func installAPK(_ source: Int32, on id: DeviceID, progress: ProgressHandler)
    async throws(TransportError) -> Outcome
  {
    guard let target = await target(id) else { return .failed(.notOverADB) }
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
    do throws(ADBError) {
      try? handle.seek(toOffset: 0)
      switch try await device.installAPK(handle, serial: target.serial, progress: progress) {
      case .installed: return .done
      case .failed(let reason): return .failed(.installFailed(reason))
      }
    } catch {
      throw Self.transportError(error)
    }
  }

  // MARK: Screenshot

  public func screenshot(_ id: DeviceID) async throws(TransportError) -> Outcome {
    guard let target = await target(id) else { return .failed(.notOverADB) }
    let image: Data
    do throws(ADBError) {
      image = try await device.screenshot(serial: target.serial)
    } catch {
      throw Self.transportError(error)
    }
    guard image.starts(with: Self.pngMagic) else { return .failed(.noImage) }
    let write: Writer = { handle throws(SaveError) in
      do {
        try handle.write(contentsOf: image)
      } catch {
        throw .transport(.io("cannot write the screenshot: \(error.localizedDescription)"))
      }
    }
    return try await save(.screenshot, of: target, at: now(), failure: .noImage, write)
  }

  static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  // MARK: Recording

  /// Records until Stop, the time limit, or the device going, then saves the video. One
  /// recording per device.
  public func startRecording(_ id: DeviceID) async throws(TransportError) -> Outcome {
    guard recordings[id] == nil else { return .failed(.alreadyRecording) }
    let recording = Recording(started: now())
    recordings[id] = recording
    let started: (Target, any ScreenRecordingControl)?
    do throws(TransportError) {
      started = try await begin(id, token: recording.token)
    } catch {
      recordings[id] = nil
      throw error
    }
    guard let (target, control) = started else {
      recordings[id] = nil
      return .failed(.notOverADB)
    }
    let watchdog = Task { [limits] in
      // screenrecord stops at its own limit; this is for one that does not.
      guard (try? await Task.sleep(for: limits.recording + limits.grace)) != nil else { return }
      log.error("a recording outlived its time limit; stopping it")
      try? await control.interrupt()
      guard (try? await Task.sleep(for: limits.stopWait)) != nil else { return }
      await control.abandon()
    }
    let end = await control.finished()
    watchdog.cancel()
    let outcome = await finish(control, end: end, target: target, started: recording.started)
    await control.discard()
    recordings[id] = nil
    return try outcome.get()
  }

  public func stopRecording(_ id: DeviceID) async throws(TransportError) -> Outcome {
    guard let recording = recordings[id] else { return .failed(.notRecording) }
    recordings[id]?.stopping = true
    // Still starting: `begin` stops it once it has a pid.
    guard let control = recording.control else { return .done }
    try await stop(id, token: recording.token, control)
    return .done
  }

  /// Sends SIGINT, and closes the recording if it has not ended `stopWait` later.
  private func stop(_ id: DeviceID, token: UUID, _ control: any ScreenRecordingControl)
    async throws(TransportError)
  {
    do throws(ADBError) {
      try await control.interrupt()
    } catch {
      throw Self.transportError(error)
    }
    Task { [limits] in
      guard (try? await Task.sleep(for: limits.stopWait)) != nil else { return }
      await self.abandon(id, token: token, control)
    }
  }

  /// Starts the recording on the device and records its control.
  private func begin(_ id: DeviceID, token: UUID) async throws(TransportError)
    -> (Target, any ScreenRecordingControl)?
  {
    guard let target = await target(id) else { return nil }
    let control: any ScreenRecordingControl
    do throws(ADBError) {
      control = try await device.recordScreen(serial: target.serial)
    } catch {
      throw Self.transportError(error)
    }
    recordings[id]?.control = control
    if recordings[id]?.stopping == true { try? await stop(id, token: token, control) }
    return (target, control)
  }

  /// Closes a recording that has not ended `stopWait` after Stop.
  private func abandon(_ id: DeviceID, token: UUID, _ control: any ScreenRecordingControl) async {
    guard recordings[id]?.token == token else { return }
    log.error("a recording did not end after Stop; closing it")
    await control.abandon()
  }

  /// Pulls the recording into a new file where screenshots go. A recording with no video (the
  /// device refused, or the process failed) is `recordingFailed` with its own words.
  private func finish(
    _ control: any ScreenRecordingControl, end: ADBScreenRecording.End, target: Target,
    started: Date
  ) async -> Result<Outcome, TransportError> {
    var detail = ""
    if case .exited(_, let text) = end { detail = text }
    let write: Writer = { handle throws(SaveError) in
      do throws(ADBError) {
        _ = try await control.pull(into: handle) { _, _ in true }
      } catch .failed {
        // The device refused the pull: there is no file.
        throw .tool(.recordingFailed(detail))
      } catch {
        throw .transport(Self.transportError(error))
      }
    }
    do throws(TransportError) {
      return .success(
        try await save(
          .recording, of: target, at: started, failure: .recordingFailed(detail), write))
    } catch {
      if case .lost(let lost) = end { return .failure(Self.transportError(lost)) }
      return .failure(error)
    }
  }
}
