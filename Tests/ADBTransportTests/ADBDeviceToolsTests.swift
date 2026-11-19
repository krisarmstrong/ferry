import DeviceKit
import Foundation
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

  @Test func installPushesRunsPMThenRemovesTheCopy() async throws {
    let device = FakeAndroid()
    let result = try await withTools(device) { tools in
      try await tools.installAPK(try apk(), serial: Self.serial, progress: ADBFixture.noProgress)
    }
    #expect(result == .installed)
    let path = try sentPath(device)
    #expect(Self.isAPKCopy(path))
    #expect(device.changes == [["pm", "install", "-r", path], ["rm", "-f", path]])
    #expect(device.installed == [Data("PK\u{3}\u{4} an app".utf8)])
    #expect(device.node(absolute: path) == nil)
  }

  @Test(arguments: [
    (Int32(1), "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n", "INSTALL_FAILED_VERSION_DOWNGRADE"),
    // Android 8 exits 0 on a failure.
    (
      0, "Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES: Failed to collect certificates]\n",
      "INSTALL_PARSE_FAILED_NO_CERTIFICATES"
    ),
  ])
  func aRefusedInstallReportsItsCodeAndRemovesTheCopy(
    status: Int32, stdout: String, code: String
  ) async throws {
    let device = FakeAndroid()
    device.setTools { $0.pmResult = FakeAndroid.ShellResult(status: status, stdout: stdout) }
    let result = try await withTools(device) { tools in
      try await tools.installAPK(try apk(), serial: Self.serial, progress: ADBFixture.noProgress)
    }
    #expect(result == .failed(code))
    #expect(device.node(absolute: try sentPath(device)) == nil)
    #expect(device.changes.last?.prefix(2) == ["rm", "-f"])
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

  @Test func aFailedPushStillRemovesTheCopy() async throws {
    let device = FakeAndroid()
    device.failNextSend("couldn't write: No space left on device")
    await #expect(throws: ADBError.self) {
      try await withTools(device) { tools in
        try await tools.installAPK(try apk(), serial: Self.serial, progress: ADBFixture.noProgress)
      }
    }
    let path = try sentPath(device)
    #expect(device.changes == [["rm", "-f", path]])
    #expect(device.node(absolute: path) == nil)
  }

  /// A cancelled install, whether while sending or while pm runs, still removes the copy.
  @Test func aCancelledPushStillRemovesTheCopy() async throws {
    let device = FakeAndroid()
    await #expect(throws: ADBError.cancelled) {
      try await withTools(device) { tools in
        try await tools.installAPK(try apk(), serial: Self.serial) { _, _ in false }
      }
    }
    let path = try sentPath(device)
    #expect(device.changes == [["rm", "-f", path]])
    #expect(device.node(absolute: path) == nil)
  }

  @Test func aCancelledInstallStillRemovesTheCopy() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.hangingPrograms = ["pm"] }
    try await withTools(device) { tools in
      let install = Task {
        try await tools.installAPK(try apk(), serial: Self.serial, progress: ADBFixture.noProgress)
      }
      let installing = try await ADBFixture.eventually {
        device.services.contains { $0.contains("pm") }
      }
      #expect(installing)
      install.cancel()
      await #expect(throws: ADBError.cancelled) { try await install.value }
    }
    let path = try sentPath(device)
    #expect(device.changes == [["rm", "-f", path]])
    #expect(device.node(absolute: path) == nil)
  }

  /// A device that leaves mid-push fails the install; the clean-up cannot reach it and says so
  /// only in the log.
  @Test func aDeviceLostMidPushFails() async throws {
    let device = FakeAndroid()
    device.dropDuring("SEND", afterBytes: 1)
    await #expect(throws: ADBError.self) {
      try await withTools(device) { tools in
        try await tools.installAPK(
          try apk(String(repeating: "a", count: 100_000)), serial: Self.serial,
          progress: ADBFixture.noProgress)
      }
    }
    #expect(device.changes.isEmpty)
  }

  // MARK: Screenshot

  @Test func aScreenshotStreamsScreencap() async throws {
    let device = FakeAndroid()
    let image = try await withTools(device) { tools in
      try await tools.screenshot(serial: Self.serial)
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
        try await tools.screenshot(serial: Self.serial)
      }
    }
  }

  /// A device that never finishes the image does not hold the request forever.
  @Test func aScreenshotThatNeverEndsTimesOut() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.hangingPrograms = ["screencap"] }
    await #expect(throws: ADBError.self) {
      try await withTools(device, captureWait: .milliseconds(200)) { tools in
        try await tools.screenshot(serial: Self.serial)
      }
    }
  }

  // MARK: Recording

  @Test func aRecordingStopsOnSIGINTAndIsPulledThenRemoved() async throws {
    let device = FakeAndroid()
    let pulled = try ADBFixture.localFile(Data())
    try await withTools(device) { tools in
      let recording = try await tools.startRecording(serial: Self.serial)
      let path = recording.devicePath
      #expect(Self.isRecording(path))
      #expect(device.commands == [["sh", "-c", ADBDeviceTools.recordScript, "sh", path]])
      try await recording.interrupt()
      #expect(await recording.finished() == .exited(status: 0, detail: ""))
      let size = try await recording.pull(
        into: try FileHandle(forWritingTo: pulled), progress: ADBFixture.noProgress)
      #expect(size == UInt64(device.state.withLock { $0.tools.recordingBytes.count }))
      await recording.discard()
      #expect(device.commands.dropFirst() == [["kill", "-2", "4242"], ["rm", "-f", path]])
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
      let recording = try await tools.startRecording(serial: Self.serial)
      #expect(await recording.finished() == .exited(status: 0, detail: ""))
      try await recording.interrupt()
      #expect(!device.commands.contains { $0.first == "kill" })
    }
  }

  @Test(arguments: ["sh: screenrecord: not found\n", "12a\n", "\n"])
  func aRecordingWithoutAPidIsRefusedAndCleanedUp(line: String) async throws {
    let device = FakeAndroid()
    device.setTools { $0.pidLine = line }
    await #expect(throws: ADBError.self) {
      try await withTools(device) { tools in try await tools.startRecording(serial: Self.serial) }
    }
    let path = try #require(device.commands.first?.last)
    #expect(device.commands.dropFirst() == [["rm", "-f", path]])
  }

  @Test func aRecordingWhoseDeviceLeavesIsLost() async throws {
    let device = FakeAndroid()
    try await withTools(device) { tools in
      let recording = try await tools.startRecording(serial: Self.serial)
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
      let recording = try await tools.startRecording(serial: Self.serial)
      #expect(device.services.first?.hasPrefix("shell:( sh '-c'") == true)
      try await recording.interrupt()
      #expect(await recording.finished() == .exited(status: 0, detail: ""))
      await recording.discard()
      #expect(
        device.commands.dropFirst() == [
          ["kill", "-2", "4242"], ["rm", "-f", recording.devicePath],
        ])
    }
  }
}
