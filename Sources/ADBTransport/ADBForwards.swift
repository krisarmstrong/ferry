import DeviceKit
import Foundation

/// Port forwards, over the host protocol: `host-serial:<serial>:list-forward`, `forward:` and
/// `killforward:`. The server answers a `forward` that worked with two `OKAY`s (the second is
/// the status), and one that did not with a single `FAIL` and its words, so `expectOkay` twice
/// reads both.
extension ADBHost {
  /// The device's TCP forwards. The server lists every device's, and reverse ones with
  /// `(reverse)` for a serial, so only the lines for `serial` count; a forward to something
  /// other than a TCP port (another tool's `localabstract:`) is not Ferry's to show.
  public func forwards(serial: String) async throws(ADBError) -> [PortForward] {
    Self.parseForwards(try await query("host-serial:\(serial):list-forward"), serial: serial)
  }

  public func addForward(serial: String, _ forward: PortForward) async throws(ADBError) {
    try await forwardRequest(
      "host-serial:\(serial):forward:tcp:\(forward.local);tcp:\(forward.remote)")
  }

  public func removeForward(serial: String, local: UInt16) async throws(ADBError) {
    try await forwardRequest("host-serial:\(serial):killforward:tcp:\(local)")
  }

  private func forwardRequest(_ request: String) async throws(ADBError) {
    let framed = try ADBWire.frame(request)
    let stream = try await ADBStream.open(port: port)
    defer { stream.cancel() }
    try await stream.write(framed)
    try await stream.expectOkay()
    try await stream.expectOkay()
  }

  /// `<serial> <local> <remote>` per line, as `format_listeners` writes it. A line with another
  /// shape, or a port outside 1...65535, is left out.
  static func parseForwards(_ text: String, serial: String) -> [PortForward] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let words = line.split(separator: " ", omittingEmptySubsequences: true)
      guard words.count == 3, words[0] == serial, let local = tcpPort(words[1]),
        let remote = tcpPort(words[2])
      else { return nil }
      return PortForward(local: local, remote: remote)
    }
  }

  private static func tcpPort(_ word: Substring) -> UInt16? {
    guard word.hasPrefix("tcp:"), let port = UInt16(word.dropFirst(4)), port >= 1 else {
      return nil
    }
    return port
  }
}
