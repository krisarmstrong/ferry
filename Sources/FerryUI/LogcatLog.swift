import Foundation

/// A line of the log as the window holds it: the text as the device sent it, its level when it
/// is a threadtime line, and an identifier that is never used twice, even after older lines are
/// dropped or the log is cleared.
struct LogcatEntry: Identifiable, Equatable {
  enum Level: Int, CaseIterable, Comparable {
    case verbose, debug, info, warning, error, fatal

    /// The level of a `logcat -v threadtime` line, `MM-DD HH:MM:SS.mmm  PID  TID L Tag: message`;
    /// `nil` for anything that does not have that shape (a marker, or text Ferry cannot place).
    init?(threadtime line: String) {
      let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
      guard parts.count == 6, Self.matches(parts[0], "dd-dd"),
        Self.matches(parts[1], "dd:dd:dd.ddd"), Int(parts[2]) != nil, Int(parts[3]) != nil,
        parts[4].count == 1, let level = parts[4].first.flatMap(Level.init(letter:)),
        parts[5].contains(": ") || parts[5].hasSuffix(":")
      else { return nil }
      self = level
    }

    /// `d` is a digit and any other character stands for itself.
    private static func matches(_ text: Substring, _ pattern: String) -> Bool {
      guard text.count == pattern.count else { return false }
      return zip(text, pattern).allSatisfy { character, expected in
        expected == "d" ? character.isASCII && character.isNumber : character == expected
      }
    }

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
    level = Level(threadtime: text)
  }
}

/// The newest lines of the log, within `capacity` lines and `byteBudget` bytes of text; older
/// ones are dropped.
struct LogcatBuffer {
  static let defaultCapacity = 50_000
  /// 50,000 lines at the 8 KB line limit would be 400 MB; this is the most text held.
  static let defaultByteBudget = 48 << 20

  private let capacity: Int
  private let byteBudget: Int
  private var entries: [LogcatEntry] = []
  private var bytes = 0
  private(set) var nextID = 0

  init(capacity: Int = Self.defaultCapacity, byteBudget: Int = Self.defaultByteBudget) {
    self.capacity = capacity
    self.byteBudget = byteBudget
  }

  var count: Int { entries.count }

  /// The identifier of the oldest line held; `nextID` when none is.
  var firstID: Int { entries.first?.id ?? nextID }

  /// Adds the lines and returns them as entries (a line the budget then dropped included).
  @discardableResult
  mutating func append(_ lines: [String]) -> [LogcatEntry] {
    var added: [LogcatEntry] = []
    added.reserveCapacity(lines.count)
    for line in lines {
      let entry = LogcatEntry(id: nextID, text: line)
      nextID += 1
      added.append(entry)
      bytes += line.utf8.count
    }
    entries.append(contentsOf: added)
    // The newest line stays, however large.
    var drop = 0
    while entries.count - drop > 1, entries.count - drop > capacity || bytes > byteBudget {
      bytes -= entries[drop].text.utf8.count
      drop += 1
    }
    if drop > 0 { entries.removeFirst(drop) }
    return added
  }

  mutating func removeAll() {
    entries.removeAll()
    bytes = 0
  }

  /// Whether `entry` is at `minimum` or above (a line with no level always is) and contains
  /// `text`, ignoring case; no text matches all.
  static func passes(_ entry: LogcatEntry, minimum: LogcatEntry.Level, matching text: String)
    -> Bool
  {
    if let level = entry.level, level < minimum { return false }
    return text.isEmpty || entry.text.range(of: text, options: [.caseInsensitive, .literal]) != nil
  }

  /// The lines that pass, as they arrived; only lines before `limit` (an identifier) when given.
  func shown(minimum: LogcatEntry.Level, matching text: String, before limit: Int? = nil)
    -> [LogcatEntry]
  {
    entries.filter { entry in
      if let limit, entry.id >= limit { return false }
      return Self.passes(entry, minimum: minimum, matching: text)
    }
  }
}
