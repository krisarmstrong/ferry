import Foundation

/// Building the command line the device's `sh` will parse. Every argument is single-quoted, so
/// a name can never end the command. Quoting does not stop a name that starts with `-` from
/// being read as an option: callers pass absolute paths (which start with `/`) or put `--`
/// first. An argument holding a NUL byte is refused: the device's shell would cut it there and
/// act on a shorter path.
public enum ADBShell {
  /// Escapes scalar by scalar: a `'` followed by a combining mark is one `Character`, so a
  /// string-level replace would leave its raw quote byte to end the quoting on the device.
  public static func quote(_ argument: String) throws(ADBError) -> String {
    guard !argument.utf8.contains(0) else { throw .invalidArgument(argument) }
    var quoted = String.UnicodeScalarView()
    quoted.append("'")
    for scalar in argument.unicodeScalars {
      if scalar == "'" {
        quoted.append(contentsOf: "'\\''".unicodeScalars)
      } else {
        quoted.append(scalar)
      }
    }
    quoted.append("'")
    return String(quoted)
  }

  /// The legacy (`shell:`) service has no exit-status channel, so the command is wrapped to print
  /// `\n<token> <status>\n` after it. The command runs in a subshell, so an `exit` in it still
  /// reaches the trailer, and `$?` is read before anything else runs. The token is fresh per
  /// call, so neither the command's own output nor a connection that drops mid-output can pass
  /// for the trailer.
  static func legacyWrapper(_ command: String, token: String) -> String {
    "(\(command)); printf '\\n%s %d\\n' '\(token)' $?"
  }

  static func newToken() -> String { "ferry-" + UUID().uuidString }

  /// Splits `<stdout>\n<token> <status>\n`. The status line is the last line; the newline
  /// before it is the wrapper's, not the command's. A pty-backed `shell:` (very old adbd) ends
  /// lines in `\r\n`, so the status line is trimmed of a trailing `\r`; stdout is left as sent.
  static func parseLegacy(_ output: Data, token: String) throws(ADBError) -> ADBShellResult {
    let newline = UInt8(ascii: "\n")
    let bytes = Array(output)
    guard bytes.last == newline, let separator = bytes.dropLast().lastIndex(of: newline),
      var line = String(bytes: bytes[(separator + 1)..<(bytes.count - 1)], encoding: .utf8)
    else { throw .protocolViolation("shell reply carries no exit status") }
    if line.hasSuffix("\r") { line.removeLast() }
    guard line.hasPrefix(token + " "), let status = Int32(line.dropFirst(token.count + 1))
    else { throw .protocolViolation("shell reply carries no exit status") }
    return ADBShellResult(
      status: status, stdout: Data(bytes[..<separator]), stderr: Data())
  }

  /// `program` is a trusted literal such as `rm`; `args` are quoted.
  public static func command(_ program: String, _ args: [String]) throws(ADBError) -> String {
    var words = [program]
    for argument in args { words.append(try quote(argument)) }
    return words.joined(separator: " ")
  }
}

public struct ADBShellResult: Sendable, Equatable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data
}

extension ADBHost {
  /// Runs `command` on the device. With `shell_v2` the status and the two streams arrive
  /// separately; without it the status rides on a final line and stderr is merged into stdout.
  public func run(serial: String, command: String) async throws(ADBError) -> ADBShellResult {
    try await run(serial: serial, command: command, token: ADBShell.newToken())
  }

  func run(
    serial: String, command: String, token: String
  ) async throws(ADBError) -> ADBShellResult {
    if try await features(serial).contains("shell_v2") {
      let stream = try await connect(serial, service: "shell,v2,raw:\(command)")
      defer { stream.cancel() }
      // Nothing is ever typed in: closing stdin up front lets a command that reads it end. A
      // failed write means the command already finished; the read below reports what happened.
      try? await stream.write(Data([Self.closeStdinPacket]) + ADBWire.le32(0))
      return try await Self.collectPackets(stream)
    }
    let stream = try await connect(
      serial, service: "shell:" + ADBShell.legacyWrapper(command, token: token))
    defer { stream.cancel() }
    return try await Self.collectLegacy(stream, token: token)
  }

  private static let stdoutPacket: UInt8 = 1
  private static let stderrPacket: UInt8 = 2
  private static let exitPacket: UInt8 = 3
  private static let closeStdinPacket: UInt8 = 4
  /// adbd never sends a shell_v2 packet larger than this.
  private static let packetLimit = 64 * 1024
  /// stdout and stderr together; a command that prints more than this is not one Ferry runs.
  private static let outputLimit = 16 * 1024 * 1024

  private static func collectPackets(_ stream: ADBStream) async throws(ADBError) -> ADBShellResult {
    var stdout = Data()
    var stderr = Data()
    while true {
      let header = try await stream.read(exactly: 5)
      let length = Int(ADBWire.u32(header.suffix(4)))
      guard length <= packetLimit else {
        throw .protocolViolation("shell packet of \(length) bytes")
      }
      let body = try await stream.read(exactly: length)
      switch header[header.startIndex] {
      case stdoutPacket, stderrPacket:
        guard stdout.count + stderr.count + length <= outputLimit else {
          throw .protocolViolation("shell output exceeds \(outputLimit) bytes")
        }
        if header[header.startIndex] == stdoutPacket {
          stdout.append(body)
        } else {
          stderr.append(body)
        }
      case exitPacket:
        guard let code = body.first else { throw .protocolViolation("empty exit packet") }
        return ADBShellResult(status: Int32(code), stdout: stdout, stderr: stderr)
      default: continue
      }
    }
  }

  private static func collectLegacy(
    _ stream: ADBStream, token: String
  ) async throws(ADBError) -> ADBShellResult {
    var output = Data()
    while let chunk = try await stream.readSome(upTo: packetLimit) {
      guard output.count + chunk.count <= outputLimit else {
        throw .protocolViolation("shell output exceeds \(outputLimit) bytes")
      }
      output.append(chunk)
    }
    return try ADBShell.parseLegacy(output, token: token)
  }
}
