import DeviceKit
import Foundation

/// What `adb connect` achieved, read from the server's device list afterwards.
public enum ADBConnectOutcome: Sendable, Equatable {
  /// Listed as a device under this adb serial.
  case connected(serial: String)
  /// Reached, but the device has not allowed this Mac yet.
  case awaitingAllow
  /// adb's own words, one bounded line.
  case failed(String)
}

public enum ADBPairOutcome: Sendable, Equatable {
  /// `guid` is the instance name the device advertises its connect service under.
  case paired(guid: String?)
  case failed(String)
}

/// One service adb's mDNS discovery lists, such as `_adb-tls-connect._tcp`.
public struct ADBMDNSService: Sendable, Equatable {
  public let name: String
  /// Without a trailing dot.
  public let type: String
  public let endpoint: WirelessEndpoint

  public init(name: String, type: String, endpoint: WirelessEndpoint) {
    self.name = name
    self.type = type
    self.endpoint = endpoint
  }

  public static let connectType = "_adb-tls-connect._tcp"
}

/// adb over the network: connecting, pairing and disconnecting through the `adb` command, and
/// what they need from the server and the device through the host protocol. It never scans a
/// network: the only addresses it learns are those adb's own mDNS lists and those a device on
/// USB reports for itself.
public struct ADBWireless: Sendable {
  private let host: ADBHost
  private let run: ADBCommandRunner
  private let answerLimit: Duration

  public init(
    host: ADBHost, run: @escaping ADBCommandRunner,
    answerLimit: Duration = ADBTransport.defaultAnswerLimit
  ) {
    self.host = host
    self.run = run
    self.answerLimit = answerLimit
  }

  /// The real server and the user's `adb`.
  public init(locator: ADBLocator = ADBLocator()) {
    self.init(host: ADBHost(locator: locator), run: ADBCommand.runner(locator: locator))
  }

  public func connect(_ endpoint: WirelessEndpoint) async throws(ADBError) -> ADBConnectOutcome {
    try await requireServer()
    let result = try await run(ADBCommand.connect(endpoint))
    let listed = try await devices().first { $0.serial == endpoint.argument }
    switch listed?.state {
    case .device: return .connected(serial: endpoint.argument)
    case .unauthorized: return .awaitingAllow
    default:
      if result.output.contains("failed to authenticate") { return .awaitingAllow }
      return .failed(Self.detail(result.output))
    }
  }

  public func disconnect(_ endpoint: WirelessEndpoint) async throws(ADBError) {
    try await requireServer()
    _ = try await run(ADBCommand.disconnect(endpoint))
  }

  /// adb prints `Successfully paired to <address> [guid=<name>]`, or `Failed: <reason>`.
  public func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async throws(ADBError)
    -> ADBPairOutcome
  {
    try await requireServer()
    let output = try await run(ADBCommand.pair(endpoint, code)).output
    guard output.contains("Successfully paired") else { return .failed(Self.detail(output)) }
    let guid = output.firstRange(of: "[guid=").flatMap { start in
      output[start.upperBound...].firstIndex(of: "]").map {
        String(output[start.upperBound..<$0])
      }
    }
    return .paired(guid: guid?.isEmpty == false ? guid : nil)
  }

  /// `name \t type \t address` per line. An address that is not one is skipped.
  public func mdnsServices() async throws(ADBError) -> [ADBMDNSService] {
    let reply = try await bounded { [host] () async throws(ADBError) in
      try await host.query("host:mdns:services")
    }
    return reply.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(separator: "\t").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard fields.count == 3,
        let endpoint = WirelessEndpoint(parsing: fields[2], defaultPort: nil)
      else { return nil }
      let type = fields[1].hasSuffix(".") ? String(fields[1].dropLast()) : fields[1]
      return ADBMDNSService(name: fields[0], type: type, endpoint: endpoint)
    }
  }

  public func devices() async throws(ADBError) -> [ADBDevice] {
    try await bounded { [host] () async throws(ADBError) in try await host.devices() }
  }

  public nonisolated func trackServer() -> AsyncStream<ADBServerEvent> {
    host.trackServer()
  }

  /// The device behind an adb serial, from its properties, as a scan names it.
  public func device(at adbSerial: String) async throws(ADBError) -> DeviceInfo? {
    try await bounded { [host] () async throws(ADBError) in
      try await ADBTransport.info(of: adbSerial, on: host)
    }
  }

  /// The port adbd listens on over TCP, if it does (`service.adb.tcp.port`).
  public func tcpPort(of adbSerial: String) async throws(ADBError) -> UInt16? {
    let value = try await bounded { [host] () async throws(ADBError) in
      try await ADBTransport.property("service.adb.tcp.port", of: adbSerial, on: host)
    }
    return UInt16(value).flatMap { $0 > 0 ? $0 : nil }
  }

  /// The device's IPv4 addresses on Ethernet and Wi-Fi, in the order `ip` lists them.
  public func networkAddresses(of adbSerial: String) async throws(ADBError) -> [String] {
    let command = try ADBShell.command("ip", ["-4", "addr"])
    let result = try await bounded { [host] () async throws(ADBError) in
      try await host.run(serial: adbSerial, command: command)
    }
    guard result.status == 0 else { throw .failed("ip exited with status \(result.status)") }
    return Self.networkAddresses(fromIPAddr: String(bytes: result.stdout, encoding: .utf8) ?? "")
  }

  /// `adb tcpip <port>`: adbd restarts listening on the network as well. Its USB route drops
  /// while it restarts.
  public func restartInTCPMode(_ adbSerial: String, port: UInt16) async throws(ADBError) {
    let reply = try await bounded { [host] () async throws(ADBError) in
      let stream = try await host.connect(adbSerial, service: "tcpip:\(port)")
      defer { stream.cancel() }
      var reply = Data()
      while let chunk = try await stream.readSome(upTo: 4096), reply.count < 4096 {
        reply.append(chunk)
      }
      return reply
    }
    let text = String(bytes: reply, encoding: .utf8) ?? ""
    guard text.contains("restarting in TCP mode") else { throw .failed(Self.detail(text)) }
  }

  private func requireServer() async throws(ADBError) {
    _ = try await bounded { [host] () async throws(ADBError) in try await host.version() }
  }

  /// Every answer from the server or a device is bounded, as a scan's are: the agent waits on
  /// these under its Wi-Fi gate, and a wedged adbd must not hold that gate forever.
  private func bounded<T: Sendable>(
    _ body: @escaping @Sendable () async throws(ADBError) -> T
  ) async throws(ADBError) -> T {
    try await ADBTransport.within(answerLimit, body)
  }

  /// The first line of adb's output, at most 200 characters: enough to say what went wrong.
  static func detail(_ output: String) -> String {
    let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
  }

  /// Interfaces whose addresses can reach the device: Ethernet (`eth*`, `eno*`) and Wi-Fi
  /// (`wlan*`). Never `lo`, `dummy*` (both NetAlly units have 10.11.12.13 there) or tunnels.
  static let networkInterfacePrefixes = ["eth", "eno", "wlan"]

  /// Reads `ip -4 addr`: a `<n>: <name>[@<peer>]: <flags> …` line per interface, then an
  /// `inet <address>/<prefix> …` line per address.
  static func networkAddresses(fromIPAddr text: String) -> [String] {
    var interface = ""
    var addresses: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let words = line.split(whereSeparator: \.isWhitespace)
      guard let first = words.first, words.count > 1 else { continue }
      if line.first?.isWhitespace == false, first.hasSuffix(":") {
        interface = String(words[1].dropLast().prefix { $0 != "@" })
        continue
      }
      guard first == "inet", networkInterfacePrefixes.contains(where: interface.hasPrefix),
        let address = ipv4(words[1])
      else { continue }
      addresses.append(address)
    }
    return addresses
  }

  /// The address of an `inet` line's `<address>/<prefix>`, if it is a dotted-decimal IPv4.
  private static func ipv4(_ word: Substring) -> String? {
    guard let address = word.split(separator: "/").first.map(String.init),
      address.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
      WirelessEndpoint(host: address, port: WirelessEndpoint.defaultPort) != nil
    else { return nil }
    return address
  }
}
