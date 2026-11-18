import Foundation

public enum ADBError: Error, Equatable, Sendable {
  /// Nothing is listening on the adb server port, or the server dropped the connection.
  case serverUnavailable
  case adbNotInstalled
  /// The server answered `FAIL` with this message.
  case failed(String)
  case deviceGone(String)
  /// The peer closed the connection (a device unplugged mid-stream, or the server stopped).
  case connectionClosed
  case protocolViolation(String)
}

public struct ADBDevice: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case device
    case unauthorized
    case offline
    case other(String)
  }

  public let serial: String
  public let state: State
  public let isWireless: Bool
  public let model: String?
  public let product: String?

  public init(
    serial: String, state: State, isWireless: Bool, model: String? = nil, product: String? = nil
  ) {
    self.serial = serial
    self.state = state
    self.isWireless = isWireless
    self.model = model
    self.product = product
  }
}

/// The adb server's host protocol framing and text formats.
enum ADBWire {
  /// A request is the payload's byte length as four hex digits, then the payload.
  static func frame(_ request: String) throws(ADBError) -> Data {
    let payload = Data(request.utf8)
    guard payload.count <= 0xFFFF else {
      throw .protocolViolation("request of \(payload.count) bytes exceeds the 4-digit length")
    }
    return Data(String(format: "%04x", payload.count).utf8) + payload
  }

  static func text(_ data: Data) throws(ADBError) -> String {
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw .protocolViolation("reply is not UTF-8")
    }
    return text
  }

  static func length(of digits: Data) throws(ADBError) -> Int {
    guard digits.count == 4, let text = String(data: digits, encoding: .ascii),
      text.allSatisfy(\.isHexDigit), let value = Int(text, radix: 16)
    else { throw .protocolViolation("bad length field \(digits.map { String($0, radix: 16) })") }
    return value
  }

  /// Parses `host:devices-l` output: one `serial state key:value…` line per device.
  static func devices(from text: String) -> [ADBDevice] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2 else { return nil }
      let serial = String(fields[0])
      var properties: [Substring: Substring] = [:]
      for field in fields.dropFirst(2) {
        guard let colon = field.firstIndex(of: ":") else { continue }
        properties[field[..<colon]] = field[field.index(after: colon)...]
      }
      return ADBDevice(
        serial: serial, state: state(String(fields[1])), isWireless: isWireless(serial),
        model: properties["model"].map(String.init),
        product: properties["product"].map(String.init))
    }
  }

  private static func state(_ word: String) -> ADBDevice.State {
    switch word {
    case "device": .device
    case "unauthorized": .unauthorized
    case "offline": .offline
    default: .other(word)
    }
  }

  /// Wireless serials are `host:port` (adb connect) or an mDNS name (`adb-<id>._adb-tls-connect…`).
  private static func isWireless(_ serial: String) -> Bool {
    serial.contains(":") || serial.contains("._adb-tls-connect.")
  }
}
