import Foundation

/// A `logcat -v threadtime` line read into its fields:
/// `MM-DD HH:MM:SS.mmm  PID  TID L Tag: message`. The tag ends at the first colon followed by a
/// space (or the end of the line), so a tag may hold spaces and a message colons. Anything that
/// does not have this shape is not one.
struct ThreadtimeLine: Equatable {
  let date: String
  let time: String
  let pid: Int
  let tid: Int
  let level: LogcatEntry.Level
  let tag: String
  let message: String

  init?(_ line: String) {
    let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
    guard parts.count == 6, Self.matches(parts[0], "dd-dd"), Self.matches(parts[1], "dd:dd:dd.ddd"),
      let pid = Int(parts[2]), let tid = Int(parts[3]), parts[4].count == 1,
      let level = parts[4].first.flatMap(LogcatEntry.Level.init(letter:))
    else { return nil }
    let rest = parts[5]
    if let separator = rest.range(of: ": ") {
      tag = String(rest[..<separator.lowerBound])
      message = String(rest[separator.upperBound...])
    } else if rest.hasSuffix(":") {
      tag = String(rest.dropLast())
      message = ""
    } else {
      return nil
    }
    date = String(parts[0])
    time = String(parts[1])
    (self.pid, self.tid, self.level) = (pid, tid, level)
  }

  /// `d` is a digit and any other character stands for itself.
  private static func matches(_ text: Substring, _ pattern: String) -> Bool {
    guard text.count == pattern.count else { return false }
    return zip(text, pattern).allSatisfy { character, expected in
      expected == "d" ? character.isASCII && character.isNumber : character == expected
    }
  }
}

/// A line of the log as the window holds it: the text as the device sent it, its level when it
/// is a threadtime line, and an identifier that is never used twice, even after older lines are
/// dropped or the log is cleared.
struct LogcatEntry: Identifiable, Equatable {
  enum Level: Int, CaseIterable, Comparable {
    case verbose, debug, info, warning, error, fatal

    init?(letter: Character) {
      guard let level = Self.allCases.first(where: { $0.letter == letter }) else { return nil }
      self = level
    }

    var letter: Character {
      switch self {
      case .verbose: "V"
      case .debug: "D"
      case .info: "I"
      case .warning: "W"
      case .error: "E"
      case .fatal: "F"
      }
    }

    static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  let id: Int
  let text: String
  /// `nil` for a line that is not threadtime: a marker such as `--------- beginning of main`, or
  /// something Ferry cannot place. It is shown at every level.
  let level: Level?

  init(id: Int, text: String) {
    self.id = id
    self.text = text
    level = ThreadtimeLine(text)?.level
  }
}

/// The newest `capacity` lines of the log; older ones are dropped.
struct LogcatBuffer {
  static let defaultCapacity = 50_000

  private let capacity: Int
  private var entries: [LogcatEntry] = []
  private(set) var nextID = 0

  init(capacity: Int = Self.defaultCapacity) {
    self.capacity = capacity
  }

  var count: Int { entries.count }

  mutating func append(_ lines: [String]) {
    for line in lines {
      entries.append(LogcatEntry(id: nextID, text: line))
      nextID += 1
    }
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
  }

  mutating func removeAll() {
    entries.removeAll()
  }

  /// The lines at `minimum` or above, and every line that has no level, that contain `text`
  /// (case-insensitively; no text matches all), as they arrived; only lines before `limit`
  /// (an identifier) when it is given.
  func shown(minimum: LogcatEntry.Level, matching text: String, before limit: Int? = nil)
    -> [LogcatEntry]
  {
    entries.filter { entry in
      if let limit, entry.id >= limit { return false }
      if let level = entry.level, level < minimum { return false }
      return text.isEmpty
        || entry.text.range(of: text, options: [.caseInsensitive, .literal]) != nil
    }
  }
}
