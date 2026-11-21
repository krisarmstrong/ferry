import ADBTransport
import DeviceKit
import FerryIPC
import Foundation

@testable import FerryAgentCore

/// adb as `WirelessADB` sees it: a scripted server and units, recording what Ferry asks of it.
actor FakeWirelessADB: WirelessADBControl {
  enum Call: Equatable, Sendable {
    case connect(String)
    case disconnect(String)
    case pair(String)
    case tcpip(String, UInt16)
    case mdns
  }

  /// Each unit reachable at an address: who it is, and whether it has allowed this Mac.
  struct Unit: Sendable {
    var info: DeviceInfo
    var authorized = true
  }

  private(set) var calls: [Call] = []
  /// adb serial → state, as `host:devices-l` lists them.
  var listed: [String: ADBDevice.State] = [:]
  /// Address (`host:port`) → the unit that answers there.
  var units: [String: Unit] = [:]
  /// USB serial → the unit on the cable, with its properties.
  var usb: [String: Unit] = [:]
  var addresses: [String: [String]] = [:]
  var tcpPorts: [String: UInt16] = [:]
  var mdns: [ADBMDNSService] = []
  var pairOutcome = ADBPairOutcome.failed("not scripted")
  var serverUp = true
  /// How long `connect` takes for an address, as an unreachable host does.
  var connectDelay: [String: Duration] = [:]
  /// What adb says when a connect to an address with no unit fails, by address; otherwise
  /// "Connection refused".
  var connectFailure: [String: String] = [:]
  /// Addresses whose next connect fails with "No route to host" whatever answers there, as
  /// through a server cut off from the network.
  var noRouteOnce: Set<String> = []
  /// Connects that throw (adb timed out), by address.
  var connectThrows: Set<String> = []
  /// Identity reads that fail, by adb serial.
  var unreadable: Set<String> = []
  /// adb serials whose device reports no serial number.
  var nameless: Set<String> = []
  /// Runs while the identity of an adb serial is read: what a scan would see then.
  var whileIdentifying: (@Sendable (String) -> Void)?
  /// Set by `holdDisconnects()`: each disconnect waits, once recorded, for `releaseDisconnects()`.
  private var disconnectsHeld = false
  private var heldDisconnects: [CheckedContinuation<Void, Never>] = []
  private(set) var inFlight = 0
  private(set) var maxInFlight = 0
  private let events: AsyncStream<ADBServerEvent>
  private let feed: AsyncStream<ADBServerEvent>.Continuation

  init() {
    (events, feed) = AsyncStream.makeStream(of: ADBServerEvent.self)
  }

  func set(_ body: @Sendable (isolated FakeWirelessADB) -> Void) { body(self) }

  /// Tells the tracker what adb lists now.
  func publish() {
    feed.yield(.devices(currentList()))
  }

  func serverGone() {
    feed.yield(.unavailable)
  }

  private func currentList() -> [ADBDevice] {
    listed.sorted { $0.key < $1.key }.map {
      ADBDevice(serial: $0.key, state: $0.value, isWireless: $0.key.contains(":"))
    }
  }

  nonisolated func trackServer() -> AsyncStream<ADBServerEvent> { events }

  private func requireServer() throws(ADBError) {
    guard serverUp else { throw .serverUnavailable }
  }

  func connect(_ endpoint: WirelessEndpoint) async throws(ADBError) -> ADBConnectOutcome {
    try requireServer()
    calls.append(.connect(endpoint.argument))
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    if let delay = connectDelay[endpoint.argument] { try? await Task.sleep(for: delay) }
    inFlight -= 1
    if connectThrows.contains(endpoint.argument) { throw .failed("adb did not finish") }
    if noRouteOnce.remove(endpoint.argument) != nil {
      return .failed("failed to connect to '\(endpoint.argument)': No route to host")
    }
    guard let unit = units[endpoint.argument] else {
      let reason = connectFailure[endpoint.argument] ?? "Connection refused"
      return .failed("failed to connect to '\(endpoint.argument)': \(reason)")
    }
    listed[endpoint.argument] = unit.authorized ? .device : .unauthorized
    return unit.authorized ? .connected(serial: endpoint.argument) : .awaitingAllow
  }

  func disconnect(_ endpoint: WirelessEndpoint) async throws(ADBError) {
    try requireServer()
    calls.append(.disconnect(endpoint.argument))
    if disconnectsHeld {
      await withCheckedContinuation { heldDisconnects.append($0) }
    }
    listed[endpoint.argument] = nil
  }

  func holdDisconnects() {
    disconnectsHeld = true
  }

  func releaseDisconnects() {
    disconnectsHeld = false
    for held in heldDisconnects { held.resume() }
    heldDisconnects = []
  }

  func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async throws(ADBError)
    -> ADBPairOutcome
  {
    try requireServer()
    calls.append(.pair(endpoint.argument))
    return pairOutcome
  }

  func mdnsServices() async throws(ADBError) -> [ADBMDNSService] {
    try requireServer()
    calls.append(.mdns)
    return mdns
  }

  func devices() async throws(ADBError) -> [ADBDevice] {
    try requireServer()
    return currentList()
  }

  func device(at adbSerial: String) async throws(ADBError) -> DeviceInfo? {
    try requireServer()
    whileIdentifying?(adbSerial)
    if unreadable.contains(adbSerial) { throw .failed("getprop failed") }
    if nameless.contains(adbSerial) { return nil }
    return (units[adbSerial] ?? usb[adbSerial])?.info
  }

  func tcpPort(of adbSerial: String) async throws(ADBError) -> UInt16? { tcpPorts[adbSerial] }

  func networkAddresses(of adbSerial: String) async throws(ADBError) -> [String] {
    addresses[adbSerial] ?? []
  }

  func restartInTCPMode(_ adbSerial: String, port: UInt16) async throws(ADBError) {
    calls.append(.tcpip(adbSerial, port))
    tcpPorts[adbSerial] = port
  }
}

/// Polls until `condition` holds, up to `timeout`.
func eventually(
  timeout: Duration = .seconds(10), _ condition: () async -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}
