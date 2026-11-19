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
  /// reaches the trailer, and `$?` is read before anything else runs. The space after `(` stops a
  /// command that itself starts with `(` from reading as `((`, an arithmetic command in bash and
  /// ksh; the newline before `)` stops a trailing `# comment` from swallowing it. The token is fresh per
  /// call, so neither the command's own output nor a connection that drops mid-output can pass
  /// for the trailer.
  static func legacyWrapper(_ command: String, token: String) -> String {
    "( \(command)\n); printf '\\n%s %d\\n' '\(token)' $?"
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
  /// `features` is the device's feature set when the caller already has it; otherwise it is
  /// asked for.
  public func run(
    serial: String, command: String, features: Set<String>? = nil
  ) async throws(ADBError) -> ADBShellResult {
    try await run(serial: serial, command: command, token: ADBShell.newToken(), features: features)
  }

  func run(
    serial: String, command: String, token: String, features: Set<String>? = nil
  ) async throws(ADBError) -> ADBShellResult {
    let channel = try await openShell(serial, command, token: token, features: features)
    defer { channel.stream.cancel() }
    guard let token = channel.token else { return try await Self.collectPackets(channel.stream) }
    return try await Self.collectLegacy(channel.stream, token: token)
  }

  /// Starts `command` over `shell,v2` when the device has it, with stdin closed up front (nothing
  /// is ever typed in, and a command that reads it then ends), else through the legacy wrapper
  /// that carries the status on a final line. The token is the wrapper's, `nil` over `shell,v2`.
  func openShell(
    _ serial: String, _ command: String, token: String, features: Set<String>?
  ) async throws(ADBError) -> (stream: ADBStream, token: String?) {
    let known: Set<String>
    if let features {
      known = features
    } else {
      known = try await self.features(serial)
    }
    if known.contains("shell_v2") {
      let stream = try await connect(serial, service: "shell,v2,raw:\(command)")
      // A failed write means the command already finished; the reads report what happened.
      try? await stream.write(Data([ShellPacket.closeStdin]) + ADBWire.le32(0))
      return (stream, nil)
    }
    let stream = try await connect(
      serial, service: "shell:" + ADBShell.legacyWrapper(command, token: token))
    return (stream, token)
  }

  /// stdout and stderr together; a command that prints more than this is not one Ferry runs.
  private static let outputLimit = 16 * 1024 * 1024

  private static func collectPackets(_ stream: ADBStream) async throws(ADBError) -> ADBShellResult {
    var stdout = Data()
    var stderr = Data()
    while true {
      let packet = try await ShellPacket.read(from: stream)
      switch packet.id {
      case ShellPacket.stdout, ShellPacket.stderr:
        guard stdout.count + stderr.count + packet.body.count <= outputLimit else {
          throw .protocolViolation("shell output exceeds \(outputLimit) bytes")
        }
        if packet.id == ShellPacket.stdout {
          stdout.append(packet.body)
        } else {
          stderr.append(packet.body)
        }
      case ShellPacket.exit:
        return ADBShellResult(
          status: try ShellPacket.status(packet.body), stdout: stdout, stderr: stderr)
      default: continue
      }
    }
  }

  private static func collectLegacy(
    _ stream: ADBStream, token: String
  ) async throws(ADBError) -> ADBShellResult {
    var output = Data()
    while let chunk = try await stream.readSome(upTo: ShellPacket.limit) {
      guard output.count + chunk.count <= outputLimit else {
        throw .protocolViolation("shell output exceeds \(outputLimit) bytes")
      }
      output.append(chunk)
    }
    return try ADBShell.parseLegacy(output, token: token)
  }
}

/// One `shell,v2` packet: an id byte, a little-endian length, and the body.
enum ShellPacket {
  static let stdout: UInt8 = 1
  static let stderr: UInt8 = 2
  static let exit: UInt8 = 3
  static let closeStdin: UInt8 = 4
  /// adbd never sends a packet larger than this.
  static let limit = 64 * 1024

  static func read(from stream: ADBStream) async throws(ADBError) -> (id: UInt8, body: Data) {
    let header = try await stream.read(exactly: 5)
    let length = Int(ADBWire.u32(header.suffix(4)))
    guard length <= limit else { throw .protocolViolation("shell packet of \(length) bytes") }
    return (header[header.startIndex], try await stream.read(exactly: length))
  }

  /// The exit packet's status byte.
  static func status(_ body: Data) throws(ADBError) -> Int32 {
    guard let code = body.first else { throw .protocolViolation("empty exit packet") }
    return Int32(code)
  }
}
