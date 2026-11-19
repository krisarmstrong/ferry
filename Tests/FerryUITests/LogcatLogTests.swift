import Foundation
import Testing

@testable import FerryUI

/// Threadtime lines read into fields, the level and text filters, and the buffer's bound.
struct LogcatLogTests {
  @Test func aThreadtimeLineIsReadIntoItsFields() throws {
    let line =
      "11-18 17:09:27.123  1234  1301 I ActivityManager: Start proc 1234:com.foo for service"
    let parsed = try #require(ThreadtimeLine(line))
    #expect(parsed.date == "11-18")
    #expect(parsed.time == "17:09:27.123")
    #expect(parsed.pid == 1234)
    #expect(parsed.tid == 1301)
    #expect(parsed.level == .info)
    #expect(parsed.tag == "ActivityManager")
    #expect(parsed.message == "Start proc 1234:com.foo for service")
  }

  @Test(arguments: [
    ("V", LogcatEntry.Level.verbose), ("D", .debug), ("I", .info), ("W", .warning), ("E", .error),
    ("F", .fatal),
  ])
  func eachLetterIsALevel(letter: String, level: LogcatEntry.Level) {
    #expect(ThreadtimeLine("01-02 03:04:05.678     1     2 \(letter) T: m")?.level == level)
  }

  /// A tag may hold spaces and a message colons: the tag ends at the first colon and space.
  @Test func theTagEndsAtTheFirstColonAndSpace() {
    let spaced = ThreadtimeLine("01-02 03:04:05.678  1  2 D My Tag: a: b")
    #expect(spaced?.tag == "My Tag")
    #expect(spaced?.message == "a: b")
    let empty = ThreadtimeLine("01-02 03:04:05.678  1  2 W Tag:")
    #expect(empty?.tag == "Tag")
    #expect(empty?.message == "")
    #expect(ThreadtimeLine("01-02 03:04:05.678  1  2 W Tag: ")?.message == "")
  }

  @Test(arguments: [
    "--------- beginning of main", "", "garbage", "01-02 03:04:05.678 x 2 I T: m",
    "01-02 03:04:05.678  1  2 S T: m", "01-02 03:04:05.678  1  2 I",
    "1-2 03:04:05.678  1  2 I T: m",
    "01-02 03:04:05  1  2 I T: m", "01-02 03:04:05.678  1  2 II T: m",
    "01-02 03:04:05.678  1  2 I no colon here",
  ])
  func anythingElseIsNotAThreadtimeLine(line: String) {
    #expect(ThreadtimeLine(line) == nil)
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
}
