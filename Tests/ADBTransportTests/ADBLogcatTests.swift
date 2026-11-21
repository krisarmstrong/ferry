import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

/// Logcat as a stream: lines split from raw chunks with a bound on any one line, read from the
/// device's `exec:` service, and ended by closing it.
@Suite(.timeLimit(.minutes(1)))
struct ADBLogcatTests {
  static let serial = "0123456789abcdef"

  private func lines(_ splitter: inout ADBLogLines, _ chunks: [String]) -> [String] {
    chunks.flatMap { splitter.append(Data($0.utf8)) }.map(Self.text)
  }

  /// A line as text; the lines in these tests are plain ASCII.
  private static func text(_ line: Data) -> String {
    String(bytes: line, encoding: .utf8) ?? ""
  }

  @Test func aLineIsOneUntilItsNewline() {
    var splitter = ADBLogLines()
    #expect(lines(&splitter, ["one\ntw", "o\nthr", "ee"]) == ["one", "two"])
    #expect(splitter.finish().map(Self.text) == "three")
    #expect(splitter.finish() == nil)
  }

  @Test func aCarriageReturnEndsNoLineAndIsDropped() {
    var splitter = ADBLogLines()
    #expect(lines(&splitter, ["a\r\nb\r", "\nc\n"]) == ["a", "b", "c"])
  }

  @Test func emptyLinesAreNotLines() {
    var splitter = ADBLogLines()
    #expect(lines(&splitter, ["\n\na\n\r\n"]) == ["a"])
  }

  /// A device that never sends a newline cannot grow the buffer: the line is cut at the limit and
  /// the rest of it, up to its newline, is dropped, so the next line is whole.
  @Test func anOverlongLineIsCutAndItsRestSkipped() {
    var splitter = ADBLogLines(limit: 8)
    var emitted: [String] = []
    for chunk in ["12345", "67890", "abcdef", "ghi\nnext\n"] {
      emitted += splitter.append(Data(chunk.utf8)).map(Self.text)
      #expect(splitter.pending <= 8)
    }
    #expect(emitted == ["12345678", "next"])
  }

  @Test func aLineOfExactlyTheLimitIsKeptWhole() {
    var splitter = ADBLogLines(limit: 4)
    #expect(lines(&splitter, ["abcd\nef\n"]) == ["abcd", "ef"])
  }

  /// Bytes are passed on as sent; the caller decodes them, so a bad sequence cannot be lost here.
  @Test func linesKeepTheirBytes() {
    var splitter = ADBLogLines()
    let bad = Data([0x66, 0xFF, 0xFE, 0x0A])
    #expect(splitter.append(bad) == [Data([0x66, 0xFF, 0xFE])])
  }

  // MARK: Over the device

  private func withLogcat<T>(
    _ device: FakeAndroid, _ body: (ADBLogcat) async throws -> T
  ) async throws -> T {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    let tools = ADBDeviceTools(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), answerLimit: .seconds(5),
      captureLimit: 1024, captureWait: .seconds(5), clock: ManualClock())
    return try await body(try await tools.logcat(route: ADBRoute(serial: Self.serial)))
  }

  @Test func linesComeFromThreadtimeLogcatOverExec() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.logcat = [Data("11-18 17:09:27.123  1234  1301 I Tag: hello\n11-18 17:0".utf8)]
      $0.logcat.append(Data("9:28.000   1   1 E T: bye\n".utf8))
    }
    try await withLogcat(device) { logcat in
      var received: [String] = []
      while received.count < 2, let next = try await logcat.next() {
        received += next.map(Self.text)
      }
      #expect(
        received == [
          "11-18 17:09:27.123  1234  1301 I Tag: hello", "11-18 17:09:28.000   1   1 E T: bye",
        ])
      logcat.close()
    }
    #expect(device.services == ["exec:logcat '-v' 'threadtime'"])
  }

  @Test func theStreamEndsWhenTheDeviceEndsIt() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.logcat = [Data("a\nb".utf8)]
      $0.logcatEnds = true
    }
    try await withLogcat(device) { logcat in
      var received: [String] = []
      while let next = try await logcat.next() {
        received += next.map(Self.text)
      }
      // The last line had no newline; it is still a line.
      #expect(received == ["a", "b"])
    }
  }

  @Test func closingStopsAReadWaitingForMore() async throws {
    let device = FakeAndroid()
    try await withLogcat(device) { logcat in
      let waiting = Task { () -> Bool in
        do { return try await logcat.next() == nil } catch { return true }
      }
      try await Task.sleep(for: .milliseconds(50))
      logcat.close()
      #expect(await waiting.value)
    }
  }

  @Test func aDeviceThatIsGoneCannotBeRead() async throws {
    let device = FakeAndroid()
    device.unplug()
    await #expect(throws: ADBError.self) {
      try await withLogcat(device) { _ in }
    }
  }
}
