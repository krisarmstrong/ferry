import Foundation

/// Building the command line the device's `sh` will parse. Every argument is single-quoted, so
/// a name can never end the command or reach another path. An argument cannot carry a NUL byte:
/// the device's shell would cut it there, so callers must refuse such names first.
public enum ADBShell {
  public static func quote(_ argument: String) -> String {
    "'" + argument.replacing("'", with: "'\\''") + "'"
  }

  /// `program` is a trusted literal such as `rm`; `args` are quoted.
  public static func command(_ program: String, _ args: [String]) -> String {
    ([program] + args.map(quote)).joined(separator: " ")
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
    if try await features(serial).contains("shell_v2") {
      let stream = try await connect(serial, service: "shell,v2,raw:\(command)")
      defer { stream.cancel() }
      return try await Self.collectPackets(stream)
    }
    let stream = try await connect(serial, service: "shell:\(command); echo; echo $?")
    defer { stream.cancel() }
    return try await Self.collectLegacy(stream)
  }

  private static let stdoutPacket: UInt8 = 1
  private static let stderrPacket: UInt8 = 2
  private static let exitPacket: UInt8 = 3

  private static func collectPackets(_ stream: ADBStream) async throws(ADBError) -> ADBShellResult {
    var stdout = Data()
    var stderr = Data()
    while true {
      let header = try await stream.read(exactly: 5)
      let length = Int(ADBWire.u32(header.suffix(4)))
      let body = try await stream.read(exactly: length)
      switch header[header.startIndex] {
      case stdoutPacket: stdout.append(body)
      case stderrPacket: stderr.append(body)
      case exitPacket:
        guard let code = body.first else { throw .protocolViolation("empty exit packet") }
        return ADBShellResult(status: Int32(code), stdout: stdout, stderr: stderr)
      default: continue
      }
    }
  }

  private static func collectLegacy(_ stream: ADBStream) async throws(ADBError) -> ADBShellResult {
    var output = Data()
    while let chunk = try await stream.readSome(upTo: 64 * 1024) { output.append(chunk) }
    // `<output>\n<status>\n`: the status is the last line, and the newline before it is ours.
    let newline = UInt8(ascii: "\n")
    guard output.last == newline, let separator = output.dropLast().lastIndex(of: newline),
      let status = String(bytes: output[(separator + 1)...].dropLast(), encoding: .utf8)
        .flatMap({ Int32($0) })
    else { throw .protocolViolation("shell reply carries no exit status") }
    return ADBShellResult(status: status, stdout: Data(output[..<separator]), stderr: Data())
  }
}
