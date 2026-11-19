import Foundation
import os

/// A shell command's output as it arrives, over `shell,v2` (framed, with an exit packet) or the
/// legacy `shell:` service (raw, with the wrapper's status line at the end).
final class ShellOutput: Sendable {
  let stream: ADBStream
  /// The legacy wrapper's token; `nil` over `shell,v2`.
  let token: String?
  private let state = OSAllocatedUnfairLock(initialState: Buffers())

  private struct Buffers {
    var stdout = Data()
    var stderr = Data()
  }

  /// Kept from each stream; a recording prints little, and only the start is shown.
  private static let keep = 64 * 1024

  init(stream: ADBStream, token: String?) {
    self.stream = stream
    self.token = token
  }

  /// The first line of stdout, without its line ending; `nil` if the command ended before
  /// printing one.
  func firstLine() async throws(ADBError) -> String? {
    var exited = false
    while true {
      let line: String? = state.withLock { buffers in
        guard let newline = buffers.stdout.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        var text = ADBDeviceTools.text(Data(buffers.stdout[..<newline]))
        if text.hasSuffix("\r") { text.removeLast() }
        buffers.stdout.removeSubrange(...newline)
        return text
      }
      if let line { return line }
      if exited { return nil }
      exited = try await readMore() != nil
    }
  }

  /// Reads until the command exits, and returns its status (`nil` when the legacy trailer is
  /// missing).
  func waitForExit() async throws(ADBError) -> Int32? {
    while true {
      if let status = try await readMore() { return status }
    }
  }

  /// The first line of what the command printed besides its pid: stderr over `shell,v2`, the
  /// merged output over the legacy service.
  var detail: String {
    state.withLock { buffers in
      var text = ADBDeviceTools.text(buffers.stderr.isEmpty ? buffers.stdout : buffers.stderr)
      if let token, let trailer = text.range(of: "\n" + token) {
        text = String(text[..<trailer.lowerBound])
      }
      let first = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
      return first.map { String($0.prefix(200)) } ?? ""
    }
  }

  /// Reads the next piece of output. Returns the exit status once the command has exited:
  /// from the exit packet, or from the legacy trailer when the connection closes.
  private func readMore() async throws(ADBError) -> Int32?? {
    if let token {
      guard let chunk = try await stream.readSome(upTo: 64 * 1024) else {
        let all = state.withLock { $0.stdout }
        return .some(try? ADBShell.parseLegacy(all, token: token).status)
      }
      append(chunk, stderr: false)
      return nil
    }
    let header = try await stream.read(exactly: 5)
    let length = Int(ADBWire.u32(header.suffix(4)))
    guard length <= 64 * 1024 else { throw .protocolViolation("shell packet of \(length) bytes") }
    let body = try await stream.read(exactly: length)
    switch header[header.startIndex] {
    case 1: append(body, stderr: false)
    case 2: append(body, stderr: true)
    case 3:
      guard let code = body.first else { throw .protocolViolation("empty exit packet") }
      return .some(Int32(code))
    default: break
    }
    return nil
  }

  private func append(_ data: Data, stderr: Bool) {
    state.withLock { buffers in
      if stderr {
        if buffers.stderr.count < Self.keep { buffers.stderr.append(data.prefix(Self.keep)) }
      } else if buffers.stdout.count < Self.keep {
        buffers.stdout.append(data.prefix(Self.keep))
      }
    }
  }
}
