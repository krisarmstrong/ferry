import Foundation
import Testing

@testable import FerryUI

/// Threadtime lines read into fields, the level and text filters, and the buffer's bound.
struct LogcatLogTests {
  @Test(arguments: [
    ("V", LogcatEntry.Level.verbose), ("D", .debug), ("I", .info), ("W", .warning), ("E", .error),
    ("F", .fatal),
  ])
  func eachLetterIsALevel(letter: String, level: LogcatEntry.Level) {
    #expect(LogcatEntry.Level(threadtime: "01-02 03:04:05.678     1     2 \(letter) T: m") == level)
  }

  @Test func aTagWithSpacesOrAnEmptyMessageStillHasALevel() {
    #expect(LogcatEntry.Level(threadtime: "01-02 03:04:05.678  1  2 D My Tag: a: b") == .debug)
    #expect(LogcatEntry.Level(threadtime: "01-02 03:04:05.678  1  2 W Tag:") == .warning)
    #expect(LogcatEntry.Level(threadtime: "01-02 03:04:05.678  1  2 W Tag: ") == .warning)
  }

  @Test(arguments: [
    "--------- beginning of main", "", "garbage", "01-02 03:04:05.678 x 2 I T: m",
    "01-02 03:04:05.678  1  2 S T: m", "01-02 03:04:05.678  1  2 I",
    "1-2 03:04:05.678  1  2 I T: m", "01-02 03:04:05  1  2 I T: m",
    "01-02 03:04:05.678  1  2 II T: m", "01-02 03:04:05.678  1  2 I no colon here",
  ])
  func anythingElseIsNotAThreadtimeLine(line: String) {
    #expect(LogcatEntry.Level(threadtime: line) == nil)
  }

  private func buffer(_ lines: [String]) -> LogcatBuffer {
    var buffer = LogcatBuffer(capacity: 100)
    buffer.append(lines)
    return buffer
  }

  static let mixed = [
    "01-02 03:04:05.001  1  2 V Chatty: verbose",
    "01-02 03:04:05.002  1  2 D Net: debug",
    "01-02 03:04:05.003  1  2 I Wifi: info",
    "01-02 03:04:05.004  1  2 W Wifi: warning",
    "01-02 03:04:05.005  1  2 E Net: error",
    "01-02 03:04:05.006  1  2 F Net: fatal",
    "--------- beginning of crash",
  ]

  /// A line that is not threadtime is shown at every level: it is a marker, or something the
  /// device wrote that Ferry cannot place.
  @Test func theLevelFilterShowsThatLevelAndAboveAndAlwaysTheUnreadable() {
    let buffer = buffer(Self.mixed)
    #expect(buffer.shown(minimum: .verbose, matching: "").count == 7)
    let warnings = buffer.shown(minimum: .warning, matching: "").map(\.text)
    #expect(
      warnings == [Self.mixed[3], Self.mixed[4], Self.mixed[5], Self.mixed[6]])
    #expect(
      buffer.shown(minimum: .fatal, matching: "").map(\.text) == [Self.mixed[5], Self.mixed[6]])
  }

  @Test func theTextFilterIgnoresCaseAndSearchesTheWholeLine() {
    let buffer = buffer(Self.mixed)
    #expect(
      buffer.shown(minimum: .verbose, matching: "wifi").map(\.text) == [
        Self.mixed[2], Self.mixed[3],
      ])
    #expect(buffer.shown(minimum: .verbose, matching: "NET").count == 3)
    #expect(
      buffer.shown(minimum: .warning, matching: "net").map(\.text) == [
        Self.mixed[4], Self.mixed[5],
      ])
    #expect(buffer.shown(minimum: .verbose, matching: "no such text").isEmpty)
  }

  /// Every line keeps its text as it arrived, and has an identifier that never repeats, even
  /// after older lines were dropped.
  @Test func theBufferKeepsTheNewestLinesWithinItsCapacity() {
    var buffer = LogcatBuffer(capacity: 50_000)
    buffer.append((0..<30_000).map { "line \($0)" })
    buffer.append((30_000..<50_010).map { "line \($0)" })
    #expect(buffer.count == 50_000)
    #expect(buffer.shown(minimum: .verbose, matching: "").first?.text == "line 10")
    #expect(buffer.shown(minimum: .verbose, matching: "").last?.text == "line 50009")
    let ids = buffer.shown(minimum: .verbose, matching: "").map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids == ids.sorted())
  }

  @Test func theDefaultCapacityIsFiftyThousandLines() {
    #expect(LogcatBuffer.defaultCapacity == 50_000)
  }

  @Test func clearingEmptiesTheBufferButNotTheNumbering() {
    var buffer = buffer(["a", "b"])
    let before = buffer.shown(minimum: .verbose, matching: "").last?.id ?? -1
    buffer.removeAll()
    #expect(buffer.count == 0)
    buffer.append(["c"])
    #expect((buffer.shown(minimum: .verbose, matching: "").first?.id ?? -1) > before)
  }

  /// Text is held within a byte budget as well as a line count: a few huge lines cannot fill
  /// the app's memory, and the newest line always stays.
  @Test func theBufferKeepsWithinItsByteBudget() {
    var buffer = LogcatBuffer(capacity: 100, byteBudget: 10)
    buffer.append(["aaaa", "bbbb", "cccc"])
    #expect(buffer.shown(minimum: .verbose, matching: "").map(\.text) == ["bbbb", "cccc"])
    buffer.append([String(repeating: "x", count: 50)])
    #expect(buffer.shown(minimum: .verbose, matching: "").map(\.text.count) == [50])
    #expect(buffer.firstID == 3)
  }
}
