import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

/// What `WirelessADB` needs of adb. `ADBWireless` is the real one; tests script a fake.
public protocol WirelessADBControl: Sendable {
  func connect(_ endpoint: WirelessEndpoint) async throws(ADBError) -> ADBConnectOutcome
  func disconnect(_ endpoint: WirelessEndpoint) async throws(ADBError)
  func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async throws(ADBError)
    -> ADBPairOutcome
  func mdnsServices() async throws(ADBError) -> [ADBMDNSService]
  func devices() async throws(ADBError) -> [ADBDevice]
  func device(at adbSerial: String) async throws(ADBError) -> DeviceInfo?
  func tcpPort(of adbSerial: String) async throws(ADBError) -> UInt16?
  func networkAddresses(of adbSerial: String) async throws(ADBError) -> [String]
  func restartInTCPMode(_ adbSerial: String, port: UInt16) async throws(ADBError)
  func trackServer() -> AsyncStream<ADBServerEvent>
}

extension ADBWireless: WirelessADBControl {}

/// The three ways onto the network, and the devices reached that way, remembered.
///
/// - **Connect by address:** `adb connect` to what the user typed (NetAlly units listen on 5555
///   once ADB is on).
/// - **Pair with code** (Android 11+): `adb pair` with the address and code the device shows,
///   then `adb connect` to the `_adb-tls-connect` service adb's mDNS lists for that device.
/// - **Use over Wi-Fi** (Android 8–10, from USB): the device's own Ethernet and Wi-Fi
///   addresses, after `tcpip 5555` unless adbd already listens on a port.
///
/// A device is remembered by its serial (`ro.serialno`), read once adb serves it, with the
/// addresses it was reached at. One that is still waiting for the user to allow this Mac is held
/// by address until adb lists it as allowed. Remembered devices are connected again when the
/// agent starts, when adb's server comes back (it drops network connections when it stops), and
/// when adb's mDNS lists them under their serial; each address is checked to answer as the
/// remembered device, and dropped again if it does not. Nothing else is ever connected to:
/// Ferry never scans a network.
///
/// Whether a device on the network is served while it is also on a cable is not decided here:
/// any USB route beats a network one (see `CompositeTransport`).
///
/// Operations take turns, so a reconnect cannot remember a device the user is forgetting.
public actor WirelessADB {
  public struct Timing: Sendable {
    /// How often adb's mDNS is read while a remembered device is missing.
    public var mdnsInterval: Duration
    /// How long to wait for a paired device's connect service, or for a device to come back on
    /// USB after `tcpip`.
    public var settle: Duration
    public var poll: Duration

    public init(
      mdnsInterval: Duration = .seconds(30), settle: Duration = .seconds(10),
      poll: Duration = .milliseconds(500)
    ) {
      self.mdnsInterval = mdnsInterval
      self.settle = settle
      self.poll = poll
    }
  }

  enum Method: String, Codable {
    /// Typed by the user.
    case address
    /// Paired with a code (Android 11+).
    case pairing
    /// Read from the device on USB.
    case network
  }

  struct Entry: Equatable {
    var name: String
    var method: Method
    var addresses: [WirelessEndpoint]
  }

  /// An address waiting for the user to allow this Mac on it.
  struct Pending {
    let method: Method
    /// The device the address must answer as, when it came from that device.
    let expected: DeviceID?
    let addresses: [WirelessEndpoint]
  }

  /// How many addresses to keep per device. A paired device moves ports; older ones only cost a
  /// failed connect.
  static let addressLimit = 4

  let adb: any WirelessADBControl
  let file: URL
  let timing: Timing
  let gate = OperationGate()
  var entries: [DeviceID: Entry]
  var pending: [WirelessEndpoint: Pending] = [:]

  public init(adb: any WirelessADBControl, store: URL, timing: Timing = Timing()) {
    self.adb = adb
    file = store
    self.timing = timing
    entries = WirelessStore.load(store)
  }

  /// `wireless.json` beside the agent's item tables.
  public static func defaultStore() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "io.github.krisarmstrong.ferry.agent/wireless.json")
  }

  public func remembered() -> [RememberedDevice] {
    entries.sorted { $0.key.serial < $1.key.serial }.map {
      RememberedDevice(id: $0.key, name: $0.value.name, addresses: $0.value.addresses)
    }
  }

  // MARK: The user's requests

  public func connect(_ endpoint: WirelessEndpoint) async -> WirelessOutcome {
    await gate.run {
      await attempt(endpoint, method: .address, expected: nil, all: [endpoint])
    }
  }

  public func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async -> WirelessOutcome {
    await gate.run { () async -> WirelessOutcome in
      do throws(ADBError) {
        switch try await adb.pair(endpoint, code: code) {
        case .failed(let detail):
          return .failed(.adb(detail))
        case .paired(let guid):
          guard let service = await connectService(guid: guid, host: endpoint.host) else {
            return .failed(.noConnectService)
          }
          return await attempt(
            service.endpoint, method: .pairing, expected: nil, all: [service.endpoint])
        }
      } catch {
        return Self.failure(error)
      }
    }
  }

  /// Puts a device that is on USB debugging on the network as well.
  public func useOverWiFi(_ id: DeviceID) async -> WirelessOutcome {
    await gate.run { () async -> WirelessOutcome in
      do throws(ADBError) {
        guard let usb = try await usbSerial(of: id) else { return .failed(.notOverUSB) }
        // Read before any restart: a unit with nowhere to go is left as it is.
        let addresses = try await adb.networkAddresses(of: usb)
        guard !addresses.isEmpty else { return .needsNetwork }
        let port: UInt16
        if let listening = try await adb.tcpPort(of: usb) {
          port = listening
        } else {
          port = WirelessEndpoint.defaultPort
          try await adb.restartInTCPMode(usb, port: port)
          await waitForUSB(usb)
        }
        let endpoints = addresses.compactMap { WirelessEndpoint(host: $0, port: port) }
        return await firstReached(endpoints, method: .network, expected: id)
      } catch {
        return Self.failure(error)
      }
    }
  }

  /// Connects a remembered device again, at its addresses or where adb's mDNS lists it.
  public func reconnect(_ id: DeviceID) async -> WirelessOutcome {
    await gate.run { () async -> WirelessOutcome in
      guard let entry = entries[id] else { return .failed(.notRemembered) }
      return await reconnect(id, entry)
    }
  }

  /// Forgets the device and disconnects adb from its addresses.
  public func forget(_ id: DeviceID) async {
    await gate.run {
      pending = pending.filter { $0.value.expected != id }
      guard let entry = entries.removeValue(forKey: id) else { return }
      save()
      log.info("forgot \(id.serial, privacy: .private)")
      for endpoint in entry.addresses {
        do throws(ADBError) {
          try await adb.disconnect(endpoint)
        } catch {
          log.info("disconnecting failed: \(String(describing: error), privacy: .private)")
        }
      }
    }
  }
}
