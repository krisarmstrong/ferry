import DeviceKit
import Foundation
import Synchronization
import os

/// What `pm install` said.
public enum APKInstallResult: Sendable, Equatable {
  case installed
  /// The code pm printed (`INSTALL_FAILED_…`, `INSTALL_PARSE_FAILED_…`), or its first line when it
  /// printed no code, at most 200 characters.
  case failed(String)
}

/// The tools a device on USB debugging offers beyond files: installing an app, a screenshot and a
/// screen recording. Each runs on its own connections, beside any session, and every command is
/// built by `ADBShell.command`.
///
/// Files Ferry puts on the device for a tool (the APK it installs, the recording before it is
/// pulled) live at paths the caller takes from `apkPath()` and `recordingPath()`, so it can note
/// them before they exist; `removeTemporary` removes one, from a task of its own so a cancelled
/// caller still cleans up, and says whether it did.
public struct ADBDeviceTools: Sendable {
  static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBTools")

  /// Where adbd's shell user may write and pm may read.
  static let apkFolder = "/data/local/tmp"
  /// Shared storage, which `screenrecord` can write and the sync service can read.
  static let recordingFolder = "/sdcard/Download"
  /// `screenrecord`'s own ceiling, which Ferry keeps.
  public static let recordingLimit = Duration.seconds(180)
  /// Runs `screenrecord` as the process whose pid it prints first, so a later `kill -2` stops
  /// that process and nothing else. The path is `$1`, passed as its own quoted argument.
  static let recordScript = "echo $$; exec screenrecord --time-limit 180 \"$1\""
  /// A 4K screen's PNG is tens of megabytes; nothing a device honestly sends is larger.
  static let defaultCaptureLimit = 128 << 20

  let host: ADBHost
  let answerLimit: Duration
  private let captureLimit: Int
  /// `screencap` answers in a second or two; a device that never finishes the image is given up.
  private let captureWait: Duration
  /// How long a capture waits for the display to come on (see `wakeScreen(route:)`), and the
  /// wait between two reads of the display's state, on the injected clock.
  let wakeLimit: Duration
  let pause: @Sendable (Duration) async throws -> Void
  /// What the answer, capture and wake limits are measured on.
  let clock: any Clock<Duration>

  public init(host: ADBHost) {
    self.init(
      host: host, answerLimit: .seconds(10), captureLimit: Self.defaultCaptureLimit,
      captureWait: .seconds(30))
  }

  init(
    host: ADBHost, answerLimit: Duration, captureLimit: Int, captureWait: Duration,
    wakeLimit: Duration = .seconds(2),
    pause: @escaping @Sendable (Duration) async throws -> Void = {
      try await ContinuousClock().sleep(for: $0)
    },
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.host = host
    self.answerLimit = answerLimit
    self.captureLimit = captureLimit
    self.captureWait = captureWait
    self.wakeLimit = wakeLimit
    self.pause = pause
    self.clock = clock
  }

  /// A new path for an APK on its way to pm.
  public static func apkPath() -> String {
    "\(apkFolder)/ferry-\(UUID().uuidString).apk"
  }

  /// A new hidden path for a recording, in the device's Download folder.
  public static func recordingPath() -> String {
    "\(recordingFolder)/.ferry-rec-\(UUID().uuidString).mp4"
  }

  /// Whether `path` is one `apkPath()` or `recordingPath()` made, so a stored path can only ever
  /// name a file Ferry created.
  public static func isTemporaryPath(_ path: String) -> Bool {
    for (prefix, suffix) in [
      ("\(apkFolder)/ferry-", ".apk"), ("\(recordingFolder)/.ferry-rec-", ".mp4"),
    ]
    where path.hasPrefix(prefix) && path.hasSuffix(suffix) {
      let middle = path.dropFirst(prefix.count).dropLast(suffix.count)
      if let uuid = UUID(uuidString: String(middle)), uuid.uuidString == middle { return true }
    }
    return false
  }

  // MARK: Installing

  /// Pushes `file` (from its current offset) to `path` on the device and installs it with
  /// `pm install -r`. The caller removes `path` afterwards, whatever happened. `progress` is
  /// asked once more, with the last values it saw, before `pm` starts, so a cancel that came
  /// after the last block still stops the install; once `pm` runs, the install finishes.
  public func installAPK(
    _ file: FileHandle, to path: String, route: ADBRoute, progress: ProgressHandler
  ) async throws(ADBError) -> APKInstallResult {
    let last = Mutex<(UInt64, UInt64)>((0, 0))
    try await push(file, to: path, route: route) { done, total in
      last.withLock { $0 = (done, total) }
      return progress(done, total)
    }
    let (done, total) = last.withLock { $0 }
    guard progress(done, total) else { throw .cancelled }
    let result = try await host.run(
      route: route, command: try ADBShell.command("pm", ["install", "-r", path]))
    return Self.installResult(result)
  }

  private func push(
    _ file: FileHandle, to path: String, route: ADBRoute, progress: ProgressHandler
  ) async throws(ADBError) {
    let features = try await host.features(route)
    let sync = ADBSync(stream: try await host.connect(route, service: "sync:"), features: features)
    do throws(ADBError) {
      try await sync.send(file, to: path, mode: 0o100644, mtime: Date(), progress: progress)
    } catch {
      await sync.quit()
      throw error
    }
    await sync.quit()
  }

  /// Reads pm's answer. Android 8's pm can exit 0 on a failure and print it on either stream, so
  /// only a `Success` line counts, and a `Failure [CODE…]` is looked for in both.
  static func installResult(_ result: ADBShellResult) -> APKInstallResult {
    let lines =
      (Self.text(result.stdout) + "\n" + Self.text(result.stderr))
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    // A failure code anywhere wins over a `Success` line, which package text could forge.
    for line in lines {
      guard let open = line.range(of: "Failure ["), let close = line.lastIndex(of: "]"),
        open.upperBound <= close
      else { continue }
      let reason = line[open.upperBound..<close]
      let code = reason.prefix { $0 != ":" && $0 != " " }
      if Self.isCode(code) { return .failed(String(code)) }
    }
    if lines.contains("Success") { return .installed }
    return .failed(String((lines.first ?? "pm printed nothing").prefix(200)))
  }

  /// What a device printed, as text; empty if it is not UTF-8.
  static func text(_ data: Data) -> String {
    String(bytes: data, encoding: .utf8) ?? ""
  }

  /// An upper-case identifier such as `INSTALL_FAILED_OLDER_SDK`.
  private static func isCode(_ text: Substring) -> Bool {
    (1...80).contains(text.count) && text.first?.isLetter == true
      && text.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
      }
  }

  // MARK: Screenshot

  /// The screen as `screencap -p` writes it (a PNG), streamed with no file on the device.
  public func screenshot(route: ADBRoute) async throws(ADBError) -> Data {
    let service = "exec:" + (try ADBShell.command("screencap", ["-p"]))
    let (host, limit) = (host, captureLimit)
    return try await ADBTransport.within(captureWait, on: clock) { () async throws(ADBError) in
      let stream = try await host.connect(route, service: service)
      defer { stream.cancel() }
      var image = Data()
      while let chunk = try await stream.readSome(upTo: 64 * 1024) {
        guard image.count + chunk.count <= limit else {
          throw .protocolViolation("screenshot exceeds \(limit) bytes")
        }
        image.append(chunk)
      }
      return image
    }
  }

  // MARK: Recording

  /// Starts `screenrecord` into `path` and returns once it has printed its pid. The recording
  /// runs until `interrupt()`, its time limit, or the connection closing. The caller removes
  /// `path` afterwards, whatever happened.
  public func startRecording(route: ADBRoute, to path: String) async throws(ADBError)
    -> ADBScreenRecording
  {
    let command = try ADBShell.command("sh", ["-c", Self.recordScript, "sh", path])
    let channel = try await host.openShell(
      route.serial, command, token: ADBShell.newToken(), features: nil,
      transportID: route.transportID)
    let output = ShellOutput(stream: channel.stream, token: channel.token)
    let recording = ADBScreenRecording(
      route: route, devicePath: path, output: output, tools: self)
    do throws(ADBError) {
      try await recording.readPID(within: answerLimit)
      return recording
    } catch {
      output.stream.cancel()
      throw error
    }
  }

  // MARK: Forwards and the program

  public func forwards(route: ADBRoute) async throws(ADBError) -> [PortForward] {
    let host = host
    return try await ADBTransport.within(answerLimit, on: clock) { () async throws(ADBError) in
      try await host.forwards(route: route)
    }
  }

  public func addForward(route: ADBRoute, _ forward: PortForward) async throws(ADBError) {
    let host = host
    try await ADBTransport.within(answerLimit, on: clock) { () async throws(ADBError) in
      try await host.addForward(route: route, forward)
    }
  }

  public func removeForward(route: ADBRoute, local: UInt16) async throws(ADBError) {
    let host = host
    try await ADBTransport.within(answerLimit, on: clock) { () async throws(ADBError) in
      try await host.removeForward(route: route, local: local)
    }
  }

  /// The `adb` the locator finds, which a shell in Terminal runs.
  ///
  /// Open in Terminal, Connect by Address and Pair with Code (`ADBCommand`) run this located adb,
  /// Ferry's fetched copy first, as a client of whatever server answers. An adb client of a
  /// different version than that server may restart it, so these can still disturb a server
  /// another adb started; Ferry itself never starts one over it. Connecting and pairing over the
  /// host protocol when a server answers is the follow-up (plan, Task 22).
  public func adbPath() -> URL? {
    host.adbURL()
  }

  // MARK: Plumbing

  /// `rm -f -- path`, run to the end even when the caller was cancelled, bounded in time. True
  /// once the path is gone (or was never there).
  public func removeTemporary(_ path: String, route: ADBRoute) async -> Bool {
    await runDetached(on: route, "rm", ["-f", "--", path], what: "removing \(path)")
  }

  /// Runs a short command on a task of its own, so a cancelled caller cannot stop it, and logs
  /// what went wrong. True when it ran and exited 0.
  func runDetached(on route: ADBRoute, _ program: String, _ args: [String], what: String) async
    -> Bool
  {
    let (host, limit, clock) = (host, answerLimit, clock)
    let result = await Task {
      do throws(ADBError) {
        let command = try ADBShell.command(program, args)
        return Result<ADBShellResult, ADBError>.success(
          try await ADBTransport.within(limit, on: clock) { () async throws(ADBError) in
            try await host.run(route: route, command: command)
          })
      } catch {
        return .failure(error)
      }
    }.value
    switch result {
    case .success(let output) where output.status == 0:
      return true
    case .success(let output):
      let detail = Self.text(output.stdout + output.stderr)
      Self.log.error(
        "\(what, privacy: .private): status \(output.status) \(detail, privacy: .private)")
    case .failure(let error):
      Self.log.error(
        "\(what, privacy: .private) failed: \(String(describing: error), privacy: .public)")
    }
    return false
  }
}

/// A `screenrecord` running on the device, from `ADBDeviceTools.startRecording`.
///
/// `finished()` follows the process until it exits; `interrupt()` sends it SIGINT, which makes
/// `screenrecord` finish the file and exit; `pull(into:)` then copies the file and `discard()`
/// removes it from the device.
public actor ADBScreenRecording {
  /// How the process ended, as far as the connection could tell.
  public enum End: Sendable, Equatable {
    /// It exited. `status` is `nil` when the connection did not carry it; `detail` is its first
    /// line of error output, at most 200 characters.
    case exited(status: Int32?, detail: String)
    /// The connection failed first (the device or the server went away).
    case lost(ADBError)
  }

  public nonisolated let devicePath: String
  let route: ADBRoute
  private let output: ShellOutput
  private let tools: ADBDeviceTools
  private(set) var pid: String?
  private var end: End?

  init(route: ADBRoute, devicePath: String, output: ShellOutput, tools: ADBDeviceTools) {
    self.route = route
    self.devicePath = devicePath
    self.output = output
    self.tools = tools
  }

  /// Reads the pid the script prints first: digits only, or the recording is refused.
  func readPID(within limit: Duration) async throws(ADBError) {
    let output = output
    let line = try await ADBTransport.within(limit, on: tools.clock) { () async throws(ADBError) in
      try await output.firstLine()
    }
    // Digits only, and never 0 or 1: `kill` would read them as the process group or init.
    guard let line, (1...10).contains(line.count), line.allSatisfy(\.isASCII),
      line.allSatisfy(\.isNumber), let number = Int(line), number >= 2
    else {
      throw .failed(
        "screenrecord did not start: \(line.map { String($0.prefix(200)) } ?? output.detail)")
    }
    pid = line
  }

  /// Waits for the process to exit. Safe to call more than once; later calls return the same.
  public func finished() async -> End {
    if let end { return end }
    let result: End
    do throws(ADBError) {
      let status = try await output.waitForExit()
      result = .exited(status: status, detail: output.detail)
    } catch {
      result = .lost(error)
    }
    output.stream.cancel()
    end = result
    return result
  }

  /// Sends SIGINT to the recording, unless it has already exited (its pid may then be another
  /// process's).
  public func interrupt() async throws(ADBError) {
    guard end == nil, let pid else { return }
    let command = try ADBShell.command("kill", ["-2", pid])
    let (host, route) = (tools.host, route)
    let result = try await ADBTransport.within(tools.answerLimit, on: tools.clock) {
      () async throws(ADBError) in
      try await host.run(route: route, command: command)
    }
    guard result.status == 0 || end != nil else {
      throw .failed(
        "kill failed: "
          + ADBDeviceTools.text(Data((result.stdout + result.stderr).prefix(200))))
    }
  }

  /// Closes the connection, for a process that does not stop: adbd hangs it up.
  public func abandon() {
    output.stream.cancel()
  }

  /// Copies the recording into `file` over `route` (the device's route now, which may differ
  /// from the one it was recorded over) and returns its size.
  public func pull(into file: FileHandle, route: ADBRoute, progress: ProgressHandler)
    async throws(ADBError) -> UInt64
  {
    let features = try await tools.host.features(route)
    let sync = ADBSync(
      stream: try await tools.host.connect(route, service: "sync:"), features: features)
    do throws(ADBError) {
      let size = try await sync.receive(devicePath, to: file, progress: progress)
      await sync.quit()
      return size
    } catch {
      await sync.quit()
      throw error
    }
  }

  /// Removes the recording from the device. True once it is gone.
  public func discard() async -> Bool {
    await tools.removeTemporary(devicePath, route: route)
  }
}
