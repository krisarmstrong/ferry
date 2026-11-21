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

/// What the server said to a host service (`ADBHost.service`).
enum ADBServiceAnswer: Sendable, Equatable {
  case reply(String)
  /// It answered `FAIL`, with this reason.
  case refused(String)

  var words: String {
    switch self {
    case .reply(let words), .refused(let words): words
    }
  }
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

/// adb over the network: connecting, pairing and disconnecting, and what they need from the
/// server and the device, all through the host protocol. It never runs an `adb` program: an adb
/// client of another version than the running server may restart it, and that server may be
/// another tool's. Without a server it fails; Ferry starts one only through `ADBHost`. It never
/// scans a network: the only addresses it learns are those adb's own mDNS lists and those a
/// device on USB reports for itself.
///
/// The requests are those `adb connect`, `adb pair` and `adb disconnect` send, in AOSP
/// packages/modules/adb at 1cf2f017d312f73b3dc53bda85ef2610e35a80e9: client/commandline.cpp
/// :1787, :1811 and :1792. The server answers connect and pair from services.cpp:137-157 and
/// disconnect from adb.cpp:1441.
public struct ADBWireless: Sendable {
  private let host: ADBHost
  private let answerLimit: Duration
  /// Holds a server replacement off while a command runs (`ADBServerKeeper.whileServing`).
  private let keeper: ADBServerKeeper
  /// What `answerLimit` and `commandLimit` are measured on.
  private let clock: any Clock<Duration>
  private let commandLimit: Duration

  /// How long a connect, pair or disconnect may take. The server connects with the system's own
  /// TCP timeout (socket_spec.cpp:224 passes no timeout), which on macOS is about 75 seconds for
  /// a host that drops the connection attempt, so this cuts an unreachable host off first; the
  /// server may still finish that connect later, which `WirelessADB` copes with. A pair has no
  /// bound in the server at all (adb_wifi.cpp waits without a timeout), so this is its only one.
  public static let defaultCommandLimit = Duration.seconds(30)

  public init(
    host: ADBHost, answerLimit: Duration = ADBTransport.defaultAnswerLimit,
    commandLimit: Duration = defaultCommandLimit, keeper: ADBServerKeeper
  ) {
    self.init(
      host: host, answerLimit: answerLimit, commandLimit: commandLimit, keeper: keeper,
      clock: ContinuousClock())
  }

  init(
    host: ADBHost, answerLimit: Duration, commandLimit: Duration, keeper: ADBServerKeeper,
    clock: any Clock<Duration>
  ) {
    self.host = host
    self.answerLimit = answerLimit
    self.keeper = keeper
    self.clock = clock
    self.commandLimit = commandLimit
  }

  /// The real server.
  public init(locator: ADBLocator = ADBLocator(), keeper: ADBServerKeeper) {
    self.init(host: ADBHost(locator: locator, keeper: keeper), keeper: keeper)
  }

  static func connectRequest(_ endpoint: WirelessEndpoint) -> String {
    "host:connect:\(endpoint.argument)"
  }

  static func disconnectRequest(_ endpoint: WirelessEndpoint) -> String {
    "host:disconnect:\(endpoint.argument)"
  }

  /// The code comes first: the server splits at the first `:` (services.cpp:271), and the
  /// address may hold more of them.
  static func pairRequest(_ endpoint: WirelessEndpoint, _ code: PairingCode) -> String {
    "host:pair:\(code.digits):\(endpoint.argument)"
  }

  /// The server answers `connected to …`, `already connected to …`, `failed to authenticate
  /// to …` or why it could not connect (client/transport_emulator.cpp:80-133), always as a reply
  /// rather than a failure, so its device list decides.
  public func connect(_ endpoint: WirelessEndpoint) async throws(ADBError) -> ADBConnectOutcome {
    let reply = try await command(Self.connectRequest(endpoint)).words
    let listed = try await devices().first { $0.serial == endpoint.argument }
    switch listed?.state {
    case .device: return .connected(serial: endpoint.argument)
    case .unauthorized: return .awaitingAllow
    default:
      if reply.contains("failed to authenticate") { return .awaitingAllow }
      return .failed(Self.detail(reply))
    }
  }

  /// An address the server no longer has (`no such device`) is already disconnected. Any other
  /// refusal, or no answer, is thrown.
  public func disconnect(_ endpoint: WirelessEndpoint) async throws(ADBError) {
    switch try await command(Self.disconnectRequest(endpoint)) {
    case .reply: return
    case .refused(let reason):
      // adb.cpp:1466: the server no longer has the address, which is what was asked for.
      if reason.hasPrefix("no such device") { return }
      throw .failed(Self.detail(reason))
    }
  }

  /// The server answers `Successfully paired to <address> [guid=<name>]`, or fails with
  /// `Failed: <reason>` (client/adb_wifi.cpp:250); a server older than pairing does not know
  /// the request.
  public func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async throws(ADBError)
    -> ADBPairOutcome
  {
    let reply: String
    switch try await command(Self.pairRequest(endpoint, code)) {
    case .reply(let words): reply = words
    case .refused(let reason): return .failed(Self.detail(Self.redacting(code, in: reason)))
    }
    // The server's own test is `StartsWith("Successful")` (services.cpp:151); a reply such as
    // `Failed: Successfully paired but …` (adb_wifi.cpp:243) is a failure.
    guard reply.hasPrefix("Successfully paired") else {
      return .failed(Self.detail(Self.redacting(code, in: reply)))
    }
    let guid = reply.firstRange(of: "[guid=").flatMap { start in
      reply[start.upperBound...].firstIndex(of: "]").map {
        String(reply[start.upperBound..<$0])
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
      try await host.run(serial: adbSerial, command: command, transportID: nil)
    }
    guard result.status == 0 else { throw .failed("ip exited with status \(result.status)") }
    return Self.networkAddresses(fromIPAddr: String(bytes: result.stdout, encoding: .utf8) ?? "")
  }

  /// `adb tcpip <port>`: adbd restarts listening on the network as well. Its USB route drops
  /// while it restarts.
  public func restartInTCPMode(_ adbSerial: String, port: UInt16) async throws(ADBError) {
    let reply = try await bounded { [host] () async throws(ADBError) in
      let stream = try await host.connect(adbSerial, service: "tcpip:\(port)", transportID: nil)
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

  /// One host service, given `commandLimit`, with no server replacement under it. The server's
  /// own refusal is an answer; running out of time, or no server, is thrown.
  private func command(_ request: String) async throws(ADBError) -> ADBServiceAnswer {
    let host = host
    let ask: @Sendable () async throws(ADBError) -> ADBServiceAnswer = {
      () async throws(ADBError) -> ADBServiceAnswer in try await host.service(request)
    }
    let body = { @Sendable [self] () async throws(ADBError) -> ADBServiceAnswer in
      try await ADBTransport.within(commandLimit, on: clock, ask)
    }
    return try await keeper.whileServing(body)
  }

  /// A server that does not know the request echoes it (`unknown host service '<request>'`,
  /// sockets.cpp:882), and a pair request carries the code: it never reaches the menu.
  static func redacting(_ code: PairingCode, in text: String) -> String {
    text.replacing(code.digits, with: "••••••")
  }

  /// Every answer from the server or a device is bounded, as a scan's are: the agent waits on
  /// these under its Wi-Fi gate, and a wedged adbd must not hold that gate forever.
  private func bounded<T: Sendable>(
    _ body: @escaping @Sendable () async throws(ADBError) -> T
  ) async throws(ADBError) -> T {
    try await ADBTransport.within(answerLimit, on: clock, body)
  }

  /// The first line of the server's words, at most 200 characters: enough to say what went wrong.
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
