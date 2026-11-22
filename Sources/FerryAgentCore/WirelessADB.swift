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
/// - **Connect by address:** the server's connect (`host:connect:`, what `adb connect` sends) to
///   what the user typed, for devices that accept ADB over the network.
/// - **Pair with code** (Android 11+): the server's pair (`host:pair:`) with the address and code
///   the device shows, then its connect to the `_adb-tls-connect` service adb's mDNS lists for
///   that device.
/// - **Use over Wi-Fi** (Android 8–10, from USB): the device's own Ethernet and Wi-Fi
///   addresses, after `tcpip 5555` unless adbd already listens on a port.
///
/// A device is remembered by its serial (`ro.serialno`), read once adb serves it, with the
/// addresses it was reached at and how each was learnt. One that is still waiting for the user to
/// allow this Mac is held by address until adb lists it as allowed, and checked again then.
///
/// adb's key authorisation does not authenticate a device over plain TCP, so any host can claim
/// a serial. A new address that answers as a device Ferry already knows (on USB, or remembered at
/// another address) is therefore disconnected at once and offered for the user to confirm; only
/// a confirmed one joins the device's entry. Addresses read from the unit over USB, and the
/// first address the user gives for a device Ferry does not know, need no confirmation.
///
/// Remembered devices are connected again when the agent starts and when adb's server comes back
/// (it drops network connections when it stops), at the addresses the user gave or confirmed and
/// those read over USB only; each must answer as the remembered device, and is dropped if it does
/// not. An address adb's mDNS lists under a remembered device's serial is offered, never
/// connected on its own. Nothing else is ever connected to: Ferry never scans a network.
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

  /// How an address was learnt, which decides whether Ferry reconnects to it on its own.
  enum Learnt: String, Codable {
    /// Given by the user for a device Ferry did not know, or confirmed by the user.
    case user
    /// Read from the unit over USB.
    case usb
    /// The connect service of a device paired with a code, which moves port each session.
    case paired

    var reconnects: Bool { self != .paired }
  }

  struct Address: Equatable {
    let endpoint: WirelessEndpoint
    var learnt: Learnt
  }

  struct Entry: Equatable {
    var name: String
    var addresses: [Address]
  }

  /// An address waiting for the user to allow this Mac on it.
  struct Pending {
    let learnt: Learnt
    /// The device the address must answer as, when that is known.
    let expected: DeviceID?
    /// Set when the user confirmed the address for `expected`.
    let confirmed: Bool
    let addresses: [WirelessEndpoint]
    /// The devices Ferry knew when the connect was made.
    let known: [DeviceID: String]
    /// `forgets` when it was made: a device forgotten since is not adopted.
    let epoch: UInt64
  }

  /// What was true when a connect began: the devices Ferry knew, and the count of forgets.
  struct Basis {
    /// Each known device with the name Ferry has for it.
    let known: [DeviceID: String]
    let epoch: UInt64
  }

  /// What a connect is for: how the address was learnt, and who it must be.
  struct Purpose {
    var learnt: Learnt
    var expected: DeviceID?
    var confirmed = false
    /// The count of forgets this connect must not predate: when a queued reconnect was planned.
    var since: UInt64?
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
  /// New addresses for known devices, waiting for the user.
  var unconfirmedAddresses: [WirelessEndpoint: UnconfirmedAddress] = [:]
  /// Addresses the user said are not the device they claimed to be, for this run.
  var ignored: Set<WirelessEndpoint> = []
  /// Counts forgets; `forgotten` records the count at each device's last forget.
  var forgets: UInt64 = 0
  var forgotten: [DeviceID: UInt64] = [:]
  /// The devices Ferry serves now, by any method.
  let known: @Sendable () async -> [DeviceID: String]
  /// The name of the Finder location Ferry has for a device, if it has one (see
  /// `DomainController.location(of:)`).
  let located: @Sendable (DeviceID) async -> String?
  /// What the hub may serve over the network, kept in step with `entries`.
  let vouching: WirelessVouching
  /// What the agent's own connection to an address finds (`LocalNetworkAccess`).
  let localNetwork: LocalNetworkAccess.Check
  /// Replaces an adb server cut off from the network; whether it did.
  let replaceCutOffServer: @Sendable () async -> Bool
  /// The reconnects started at agent start or when adb's server came back, if still running.
  var reconnecting: Task<Void, Never>?
  /// What adb listed when its server came back during a reconnect pass: another pass runs
  /// against it once that one ends.
  var queuedPass: [ADBDevice]?
  /// How many startup reconnects run at once.
  static let reconnectLimit = 4

  /// `known` lists the devices Ferry serves now (the hub's), with their names, so a network host
  /// claiming one of their serials is not believed without the user, and the user is asked about
  /// it by the name Ferry has, not the one the host reports. `located` extends that to devices
  /// that are unplugged but have a Finder location, which such a host would otherwise take over.
  /// `vouching` is shared with the `ADBTransport` that serves network routes.
  /// `localNetwork` is asked only when adb finds no route to an address; when the agent reaches
  /// it anyway, `replaceCutOffServer` replaces the server (`ADBServerKeeper.replaceFerryServer`).
  public init(
    adb: any WirelessADBControl, store: URL, timing: Timing = Timing(),
    known: @escaping @Sendable () async -> [DeviceID: String] = { [:] },
    located: @escaping @Sendable (DeviceID) async -> String? = { _ in nil },
    vouching: WirelessVouching = WirelessVouching(),
    localNetwork: @escaping LocalNetworkAccess.Check = { _ in .unknown },
    replaceCutOffServer: @escaping @Sendable () async -> Bool = { false }
  ) {
    self.adb = adb
    file = store
    self.timing = timing
    self.known = known
    self.located = located
    self.vouching = vouching
    self.localNetwork = localNetwork
    self.replaceCutOffServer = replaceCutOffServer
    let loaded = WirelessStore.load(store)
    entries = loaded.entries
    if !loaded.intact { vouching.storeUnreadable() }
    vouching.remember(loaded.entries)
  }

  /// `wireless.json` beside the agent's item tables.
  public static func defaultStore() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "io.github.krisarmstrong.ferry.agent/wireless.json")
  }

  public func remembered() -> [RememberedDevice] {
    entries.sorted { $0.key.serial < $1.key.serial }.map {
      RememberedDevice(
        id: $0.key, name: $0.value.name, addresses: $0.value.addresses.map(\.endpoint))
    }
  }

  public func unconfirmed() -> [UnconfirmedAddress] {
    unconfirmedAddresses.values.sorted { $0.address.argument < $1.address.argument }
  }

  // MARK: The user's requests

  public func connect(_ endpoint: WirelessEndpoint) async -> WirelessOutcome {
    await gate.run {
      await attempt(endpoint, for: Purpose(learnt: .user), all: [endpoint])
    }
  }

  public func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async -> WirelessOutcome {
    await gate.run { () async -> WirelessOutcome in
      // The connect service is matched by address, so the pairing host must be the address the
      // device shows; a name never matches what adb's mDNS lists.
      guard endpoint.isAddressLiteral else { return .failed(.pairingNeedsAddress) }
      do throws(ADBError) {
        switch try await adb.pair(endpoint, code: code) {
        case .failed(let detail):
          return .failed(await failure(reaching: endpoint, detail))
        case .paired(let guid):
          guard let service = await connectService(guid: guid, pairedAt: endpoint) else {
            return .failed(.noConnectService)
          }
          return await attempt(
            service.endpoint, for: Purpose(learnt: .paired), all: [service.endpoint])
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
        return await firstReached(endpoints, for: Purpose(learnt: .usb, expected: id))
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

  /// The user says the address is the device the menu showed: the offer must still be exactly
  /// that (address, device and name), and the address must answer as that device again before
  /// it joins the entry.
  public func confirm(_ shown: UnconfirmedAddress) async -> WirelessOutcome {
    await gate.run { () async -> WirelessOutcome in
      guard unconfirmedAddresses[shown.address] == shown else { return .failed(.offerChanged) }
      unconfirmedAddresses[shown.address] = nil
      return await attempt(
        shown.address, for: Purpose(learnt: .user, expected: shown.id, confirmed: true),
        all: [shown.address])
    }
  }

  public func ignore(_ address: WirelessEndpoint) async {
    await gate.run {
      unconfirmedAddresses[address] = nil
      ignored.insert(address)
    }
  }

  /// Forgets every remembered device, and withdraws every address waiting for the user, as
  /// Remove Ferry does. A device remembered meanwhile (a connect queued behind a forget) is
  /// forgotten too: it repeats until nothing is left.
  public func forgetAll() async {
    repeat {
      while let id = entries.keys.min(by: { $0.serial < $1.serial }) { await forget(id) }
      await gate.run { unconfirmedAddresses = [:] }
    } while !entries.isEmpty
  }

  /// Forgets the device and revokes everything under way for it: disconnects adb from its
  /// addresses and from connections waiting for Allow at them, and drops its offers. A waiting
  /// connection elsewhere that turns out to be this device is dropped when it resolves.
  public func forget(_ id: DeviceID) async {
    await gate.run {
      forgets += 1
      forgotten[id] = forgets
      vouching.forgot(id)
      let addresses = Set(entries.removeValue(forKey: id)?.addresses.map(\.endpoint) ?? [])
      let revoked = pending.filter {
        $0.value.expected == id || addresses.contains($0.key)
          || !addresses.isDisjoint(with: $0.value.addresses)
      }
      for endpoint in revoked.keys { pending[endpoint] = nil }
      unconfirmedAddresses = unconfirmedAddresses.filter { $0.value.id != id }
      // Held as undecided before they stop being vouched for: until they are disconnected, a
      // scan would otherwise find a located device on an unvouched route and offer it.
      for endpoint in addresses { vouching.unsettle(endpoint.argument) }
      save()
      log.info("forgot \(id.serial, privacy: .private)")
      for endpoint in addresses.union(revoked.keys).sorted(by: { $0.argument < $1.argument }) {
        do throws(ADBError) {
          try await adb.disconnect(endpoint)
        } catch {
          log.info("disconnecting failed: \(String(describing: error), privacy: .private)")
        }
      }
      // Only once disconnected: the device is unknown to Ferry now, which a scan would serve.
      // Each hold is released once: an address both remembered and pending has two.
      for endpoint in addresses { vouching.settle(endpoint.argument) }
      for endpoint in revoked.keys { vouching.settle(endpoint.argument) }
    }
  }
}
