import DeviceKit
import Foundation
import Synchronization
import Testing

@testable import ADBTransport

/// APK install, screenshot and screen recording against `FakeAndroid`: the exact command lines,
/// and that the files Ferry puts on the device are removed whatever happens.
@Suite(.timeLimit(.minutes(1)))
struct ADBDeviceToolsTests {
  static let serial = "0123456789abcdef"
  /// `prefix`, a fresh UUID, then `suffix`.
  static func isFresh(_ path: String, _ prefix: String, _ suffix: String) -> Bool {
    path.hasPrefix(prefix) && path.hasSuffix(suffix)
      && UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(suffix.count))) != nil
  }

  static func isAPKCopy(_ path: String) -> Bool {
    isFresh(path, "/data/local/tmp/ferry-", ".apk")
  }

  static func isRecording(_ path: String) -> Bool {
    isFresh(path, "/sdcard/Download/.ferry-rec-", ".mp4")
  }

  /// Runs `body` with tools on a server for `device`, then stops the server.
  private func withTools<T>(
    _ device: FakeAndroid, captureLimit: Int = ADBDeviceTools.defaultCaptureLimit,
    captureWait: Duration = .seconds(5), _ body: (ADBDeviceTools) async throws -> T
  ) async throws -> T {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    let tools = ADBDeviceTools(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), answerLimit: .seconds(5),
      captureLimit: captureLimit, captureWait: captureWait)
    return try await body(tools)
  }

  private func apk(_ contents: String = "PK\u{3}\u{4} an app") throws -> FileHandle {
    try FileHandle(forReadingFrom: ADBFixture.localFile(Data(contents.utf8)))
  }

  /// The path the APK was sent to, from the device's SEND request (`path,mode`).
  private func sentPath(_ device: FakeAndroid) throws -> String {
    let send = try #require(device.syncRequests.first { $0.id == "SEND" })
    return String(try #require(send.path.split(separator: ",").first))
  }

  // MARK: Installing

  @Test func installPushesToItsPathAndRunsPM() async throws {
    let device = FakeAndroid()
    let path = ADBDeviceTools.apkPath()
    let result = try await withTools(device) { tools in
      try await tools.installAPK(
        try apk(), to: path, route: ADBRoute(serial: Self.serial), progress: ADBFixture.noProgress)
    }
    #expect(result == .installed)
    #expect(Self.isAPKCopy(path))
    #expect(try sentPath(device) == path)
    #expect(device.changes == [["pm", "install", "-r", path]])
    #expect(device.installed == [Data("PK\u{3}\u{4} an app".utf8)])
  }

  @Test(arguments: [
    (Int32(1), "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n", "INSTALL_FAILED_VERSION_DOWNGRADE"),
    // Android 8 exits 0 on a failure.
    (
      0, "Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES: Failed to collect certificates]\n",
      "INSTALL_PARSE_FAILED_NO_CERTIFICATES"
    ),
  ])
  func aRefusedInstallReportsItsCode(status: Int32, stdout: String, code: String) async throws {
    let device = FakeAndroid()
    device.setTools { $0.pmResult = FakeAndroid.ShellResult(status: status, stdout: stdout) }
    let result = try await withTools(device) { tools in
      try await tools.installAPK(
        try apk(), to: ADBDeviceTools.apkPath(), route: ADBRoute(serial: Self.serial),
        progress: ADBFixture.noProgress)
    }
    #expect(result == .failed(code))
  }

  /// `rm -f --`, with the path as its own quoted argument, run even for a cancelled caller.
  @Test func aTemporaryFileIsRemovedEvenByACancelledCaller() async throws {
    let device = FakeAndroid()
    let path = ADBDeviceTools.apkPath()
    try await withTools(device) { tools in
      _ = try await tools.installAPK(
        try apk(), to: path, route: ADBRoute(serial: Self.serial), progress: ADBFixture.noProgress)
      let removal = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await tools.removeTemporary(path, route: ADBRoute(serial: Self.serial))
      }
      #expect(await removal.value)
      // Already gone: still true.
      #expect(await tools.removeTemporary(path, route: ADBRoute(serial: Self.serial)))
    }
    #expect(device.changes.dropFirst() == [["rm", "-f", "--", path], ["rm", "-f", "--", path]])
    #expect(device.node(absolute: path) == nil)
  }

  @Test func aTemporaryFileOnADeviceThatLeftIsNotRemoved() async throws {
    let device = FakeAndroid()
    device.unplug()
    let removed = try await withTools(device) { tools in
      await tools.removeTemporary(ADBDeviceTools.apkPath(), route: ADBRoute(serial: Self.serial))
    }
    #expect(!removed)
  }

  @Test func onlyToolPathsAreTemporary() {
    #expect(ADBDeviceTools.isTemporaryPath(ADBDeviceTools.apkPath()))
    #expect(ADBDeviceTools.isTemporaryPath(ADBDeviceTools.recordingPath()))
    let uuid = UUID().uuidString
    for path in [
      "/data/local/tmp/app.apk", "/data/local/tmp/ferry-\(uuid.lowercased()).apk",
      "/data/local/tmp/ferry-../../system/\(uuid).apk", "/sdcard/Download/ferry-\(uuid).apk",
      "/sdcard/Download/.ferry-rec-\(uuid).apk", "/sdcard/DCIM/.ferry-rec-\(uuid).mp4", "",
    ] {
      #expect(!ADBDeviceTools.isTemporaryPath(path), "\(path)")
    }
  }

  @Test(arguments: [
    (stdout: "Success\n", stderr: "", result: APKInstallResult.installed),
    ("\tpkg: /data/local/tmp/x.apk\r\nSuccess\r\n", "", .installed),
    (
      "", "Failure [INSTALL_FAILED_OLDER_SDK: Requires newer sdk version #30]",
      .failed("INSTALL_FAILED_OLDER_SDK")
    ),
    (
      "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]", "",
      .failed("INSTALL_FAILED_INSUFFICIENT_STORAGE")
    ),
    // Not a code in the brackets: the line itself.
    ("Failure [not a code]", "", .failed("Failure [not a code]")),
    (
      "", "Error: java.lang.SecurityException: denied",
      .failed("Error: java.lang.SecurityException: denied")
    ),
    ("", "", .failed("pm printed nothing")),
    // A failure code wins over a Success line, which package text could forge.
    (
      "Success\nFailure [INSTALL_FAILED_VERSION_DOWNGRADE]\n", "",
      .failed("INSTALL_FAILED_VERSION_DOWNGRADE")
    ),
    ("Success\n", "Failure [INSTALL_FAILED_TEST_ONLY]", .failed("INSTALL_FAILED_TEST_ONLY")),
    // "Success" inside a longer line is not success.
    ("Successfully nothing", "", .failed("Successfully nothing")),
  ])
  func pmOutputIsRead(stdout: String, stderr: String, result: APKInstallResult) {
    let output = ADBShellResult(status: 0, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    #expect(ADBDeviceTools.installResult(output) == result)
  }

  @Test func aLongLineIsCut() {
    let line = String(repeating: "x", count: 500)
    let output = ADBShellResult(status: 1, stdout: Data(line.utf8), stderr: Data())
    #expect(ADBDeviceTools.installResult(output) == .failed(String(repeating: "x", count: 200)))
  }

  /// A device that leaves mid-push fails the install.
  @Test func aDeviceLostMidPushFails() async throws {
    let device = FakeAndroid()
    device.dropDuring("SEND", afterBytes: 1)
    await #expect(throws: ADBError.self) {
      try await withTools(device) { tools in
        try await tools.installAPK(
          try apk(String(repeating: "a", count: 100_000)), to: ADBDeviceTools.apkPath(),
          route: ADBRoute(serial: Self.serial), progress: ADBFixture.noProgress)
      }
    }
    #expect(device.changes.isEmpty)
  }

  // MARK: Screenshot

  @Test func aScreenshotStreamsScreencap() async throws {
    let device = FakeAndroid()
    let image = try await withTools(device) { tools in
      try await tools.screenshot(route: ADBRoute(serial: Self.serial))
    }
    #expect(image == device.state.withLock { $0.tools.screencap })
    #expect(device.services == ["exec:screencap '-p'"])
    // Nothing is written on the device.
    #expect(device.syncRequests.isEmpty)
  }

  @Test func aScreenshotOverTheLimitIsRefused() async throws {
    let device = FakeAndroid()
    await #expect(throws: ADBError.protocolViolation("screenshot exceeds 1000 bytes")) {
      try await withTools(device, captureLimit: 1000) { tools in
        try await tools.screenshot(route: ADBRoute(serial: Self.serial))
      }
    }
  }

  /// A device that never finishes the image does not hold the request forever.
  @Test func aScreenshotThatNeverEndsTimesOut() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.hangingPrograms = ["screencap"] }
    await #expect(throws: ADBError.self) {
      try await withTools(device, captureWait: .milliseconds(200)) { tools in
        try await tools.screenshot(route: ADBRoute(serial: Self.serial))
      }
    }
  }

  // MARK: Recording

  @Test func aRecordingStopsOnSIGINTAndIsPulledThenRemoved() async throws {
    let device = FakeAndroid()
    let pulled = try ADBFixture.localFile(Data())
    try await withTools(device) { tools in
      let recording = try await tools.startRecording(
        route: ADBRoute(serial: Self.serial), to: ADBDeviceTools.recordingPath())
      let path = recording.devicePath
      #expect(Self.isRecording(path))
      #expect(device.commands == [["sh", "-c", ADBDeviceTools.recordScript, "sh", path]])
      try await recording.interrupt()
      #expect(await recording.finished() == .exited(status: 0, detail: ""))
      let size = try await recording.pull(
        into: try FileHandle(forWritingTo: pulled), route: ADBRoute(serial: Self.serial),
        progress: ADBFixture.noProgress)
      #expect(size == UInt64(device.state.withLock { $0.tools.recordingBytes.count }))
      #expect(await recording.discard())
      #expect(device.commands.dropFirst() == [["kill", "-2", "4242"], ["rm", "-f", "--", path]])
      #expect(device.node(absolute: path) == nil)
    }
    #expect(try Data(contentsOf: pulled) == device.state.withLock { $0.tools.recordingBytes })
  }

  /// A recording that ended by itself (its time limit) is not signalled: its pid may be another
  /// process's by then.
  @Test func aFinishedRecordingIsNotSignalled() async throws {
    let device = FakeAndroid()
    device.setTools { $0.recordingEndsOnItsOwn = true }
    try await withTools(device) { tools in
      let recording = try await tools.startRecording(
        route: ADBRoute(serial: Self.serial), to: ADBDeviceTools.recordingPath())
      #expect(await recording.finished() == .exited(status: 0, detail: ""))
      try await recording.interrupt()
      #expect(!device.commands.contains { $0.first == "kill" })
    }
  }

  @Test(arguments: ["sh: screenrecord: not found\n", "12a\n", "\n", "0\n", "1\n"])
  func aRecordingWithoutAPidIsRefused(line: String) async throws {
    let device = FakeAndroid()
    device.setTools { $0.pidLine = line }
    await #expect(throws: ADBError.self) {
      try await withTools(device) { tools in
        try await tools.startRecording(
          route: ADBRoute(serial: Self.serial), to: ADBDeviceTools.recordingPath())
      }
    }
    #expect(device.commands.count == 1)
  }

  @Test func aRecordingWhoseDeviceLeavesIsLost() async throws {
    let device = FakeAndroid()
    try await withTools(device) { tools in
      let recording = try await tools.startRecording(
        route: ADBRoute(serial: Self.serial), to: ADBDeviceTools.recordingPath())
      device.unplug()
      guard case .lost = await recording.finished() else {
        Issue.record("the recording did not report the connection lost")
        return
      }
    }
  }

  /// Without `shell_v2` the pid comes first on the merged output and the status on the
  /// wrapper's trailer.
  @Test func aRecordingWorksOverTheLegacyShell() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.features = "cmd,stat_v2" }
    try await withTools(device) { tools in
      let recording = try await tools.startRecording(
        route: ADBRoute(serial: Self.serial), to: ADBDeviceTools.recordingPath())
      #expect(device.services.first?.hasPrefix("shell:( sh '-c'") == true)
      try await recording.interrupt()
      #expect(await recording.finished() == .exited(status: 0, detail: ""))
      #expect(await recording.discard())
      #expect(
        device.commands.dropFirst() == [
          ["kill", "-2", "4242"], ["rm", "-f", "--", recording.devicePath],
        ])
    }
  }
}

// MARK: Cancelling an install

extension ADBDeviceToolsTests {
  /// A cancel during the copy stops it, and `pm` never runs.
  @Test func aCancelDuringTheCopyStopsTheInstall() async throws {
    let device = FakeAndroid()
    await #expect(throws: ADBError.cancelled) {
      try await withTools(device) { tools in
        try await tools.installAPK(
          try apk(String(repeating: "x", count: 200_000)), to: ADBDeviceTools.apkPath(),
          route: ADBRoute(serial: Self.serial)
        ) { _, _ in false }
      }
    }
    #expect(device.installed.isEmpty)
    #expect(!device.changes.contains { $0.first == "pm" })
  }

  /// A cancel that comes after the last block still stops the install before `pm` runs.
  @Test func aCancelAfterTheLastBlockStopsTheInstall() async throws {
    let device = FakeAndroid()
    let finished = Mutex(0)
    // The copy's last report says go on; the cancel comes just after it.
    let progress: ProgressHandler = { done, total in
      finished.withLock { count in
        if done == total { count += 1 }
        return count < 2
      }
    }
    await #expect(throws: ADBError.cancelled) {
      try await withTools(device) { tools in
        try await tools.installAPK(
          try apk(), to: ADBDeviceTools.apkPath(), route: ADBRoute(serial: Self.serial),
          progress: progress)
      }
    }
    #expect(device.installed.isEmpty)
    #expect(!device.changes.contains { $0.first == "pm" })
  }
}
