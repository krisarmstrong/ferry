import Foundation

/// Splits what logcat sends into lines, holding at most `limit` bytes of a line that has not
/// ended yet: a device that never sends a newline cannot grow the buffer. A line that reaches
/// the limit is passed on cut there, and the rest of it, up to its newline, is dropped. A `\r`
/// before a newline is dropped, and an empty line is not a line. Lines are bytes, as sent: the
/// caller decodes them, so no malformed sequence is lost here.
struct ADBLogLines: Sendable {
  /// 8 KB: a threadtime line is a short prefix and a message; a longer message is cut.
  static let defaultLimit = 8 * 1024

  private let limit: Int
  private var carry = Data()
  private var skipping = false

  init(limit: Int = Self.defaultLimit) {
    self.limit = limit
  }

  /// The bytes of a line held until its newline arrives.
  var pending: Int { carry.count }

  mutating func append(_ chunk: Data) -> [Data] {
    var lines: [Data] = []
    var rest = chunk[...]
    while !rest.isEmpty {
      let newline = rest.firstIndex(of: UInt8(ascii: "\n"))
      let piece = rest[..<(newline ?? rest.endIndex)]
      rest = newline.map { rest[rest.index(after: $0)...] } ?? Data()[...]
      if skipping {
        if newline != nil { skipping = false }
        continue
      }
      let room = limit - carry.count
      if piece.count > room {
        carry.append(piece.prefix(room))
        skipping = newline == nil
        if let line = take() { lines.append(line) }
        // The rest of an overlong line is dropped even though its newline came in this chunk.
        continue
      }
      carry.append(piece)
      if newline != nil {
        if let line = take() { lines.append(line) }
      } else if carry.count == limit {
        // Full with nothing more to hold: ends here, and what follows up to a newline is dropped.
        skipping = true
        if let line = take() { lines.append(line) }
      }
    }
    return lines
  }

  /// The line left when the stream ended without a newline.
  mutating func finish() -> Data? {
    skipping = false
    return take()
  }

  private mutating func take() -> Data? {
    defer { carry = Data() }
    if carry.last == UInt8(ascii: "\r") { carry.removeLast() }
    return carry.isEmpty ? nil : carry
  }
}

/// `logcat -v threadtime` running on a device, read as lines. It follows the log until it is
/// closed or the device goes away.
public actor ADBLogcat {
  private let stream: ADBStream
  private var lines: ADBLogLines
  private var ended = false

  init(stream: ADBStream, lineLimit: Int = ADBLogLines.defaultLimit) {
    self.stream = stream
    lines = ADBLogLines(limit: lineLimit)
  }

  /// The next lines, as bytes; `nil` once the device ended the log. A closed stream, or a
  /// device that left, throws.
  public func next() async throws(ADBError) -> [Data]? {
    while !ended {
      guard let chunk = try await stream.readSome(upTo: 64 * 1024) else {
        ended = true
        return lines.finish().map { [$0] }
      }
      let found = lines.append(chunk)
      if !found.isEmpty { return found }
    }
    return nil
  }

  /// Closes the connection, which adbd answers by ending logcat. A read waiting for more fails.
  public nonisolated func close() {
    stream.cancel()
  }
}

extension ADBDeviceTools {
  /// Starts logcat over `exec:`, which carries the bytes as they are, with no terminal and no
  /// framing, as for a screenshot.
  public func logcat(route: ADBRoute) async throws(ADBError) -> ADBLogcat {
    let service = "exec:" + (try ADBShell.command("logcat", ["-v", "threadtime"]))
    return ADBLogcat(stream: try await host.connect(route, service: service))
  }
}
