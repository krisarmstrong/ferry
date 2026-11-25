import DeviceKit
import Foundation

/// Port forwards, over the host protocol: `<route>:list-forward`, `forward:` and
/// `killforward:`. The server answers a `forward` that worked with two `OKAY`s (the second is
/// the status), and one that did not with a single `FAIL` and its words, so `expectOkay` twice
/// reads both.
extension ADBHost {
  /// The device's TCP forwards. The server lists every device's, and reverse ones with
  /// `(reverse)` for a serial, so only the lines for the route's serial count; a forward to something
  /// other than a TCP port (another tool's `localabstract:`) is not Ferry's to show.
  public func forwards(route: ADBRoute) async throws(ADBError) -> [PortForward] {
    Self.parseForwards(
      try await query("\(Self.prefix(route)):list-forward"), serial: route.serial)
  }

  /// `norebind:` makes adb refuse a Mac port it already forwards. Without it adb silently points
  /// the existing forward at this device, even one another device or tool made.
  public func addForward(route: ADBRoute, _ forward: PortForward) async throws(ADBError) {
    try await forwardRequest(
      "\(Self.prefix(route)):forward:norebind:tcp:\(forward.local);tcp:\(forward.remote)")
  }

  public func removeForward(route: ADBRoute, local: UInt16) async throws(ADBError) {
    try await forwardRequest("\(Self.prefix(route)):killforward:tcp:\(local)")
  }

  private func forwardRequest(_ request: String) async throws(ADBError) {
    let framed = try ADBWire.frame(request)
    let stream = try await open()
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
