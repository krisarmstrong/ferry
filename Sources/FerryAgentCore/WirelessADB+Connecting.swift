import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

/// Following adb's server, and the connecting every request and reconnect shares.
extension WirelessADB {

  /// Follows adb's server until the calling task is cancelled: remembers devices once they are
  /// allowed, reconnects remembered ones at start and whenever the server comes back, and reads
  /// adb's mDNS while one is missing. Call it once.
  public func run() async {
    let poller = Task { await self.pollMDNS() }
    defer { poller.cancel() }
    var reconnectDue = true
    for await event in adb.trackServer() {
      switch event {
      case .unavailable:
        reconnectDue = true
      case .devices(let listed):
        await gate.run { await resolvePending(listed) }
        guard reconnectDue else { continue }
        reconnectDue = false
        await gate.run { await reconnectMissing(listed) }
      }
    }
  }

  func pollMDNS() async {
    while (try? await Task.sleep(for: timing.mdnsInterval)) != nil {
      await gate.run { await offerFromMDNS() }
    }
  }

  /// Adopts each waiting address adb now lists as allowed, checked as it would have been at
  /// connect time, unless the device it answers as was forgotten since.
  func resolvePending(_ listed: [ADBDevice]) async {
    let allowed = Set(listed.filter { $0.state == .device }.map(\.serial))
    for (endpoint, waiting) in pending where allowed.contains(endpoint.argument) {
      pending[endpoint] = nil
      _ = await adopt(
        endpoint.argument, at: endpoint,
        for: Purpose(
          learnt: waiting.learnt, expected: waiting.expected, confirmed: waiting.confirmed),
        all: waiting.addresses, known: waiting.known, since: waiting.epoch)
    }
  }

  func reconnectMissing(_ listed: [ADBDevice]) async {
    for (id, entry) in entries where isMissing(id, entry, from: listed) {
      _ = await reconnect(id, entry)
    }
  }

  /// Reads adb's mDNS only while a remembered device is missing, and offers a connect service
  /// named for its serial to the user; it is never connected to here.
  func offerFromMDNS() async {
    guard let listed = try? await adb.devices() else { return }
    let missing = entries.filter { isMissing($0.key, $0.value, from: listed) }
    guard !missing.isEmpty, let services = try? await adb.mdnsServices() else { return }
    for (id, entry) in missing {
      if let service = services.first(where: { Self.advertises($0, id) }) {
        offer(service.endpoint, as: id, named: entry.name)
      }
    }
  }

  /// adb lists none of its addresses, and no mDNS connection named for it.
  func isMissing(_ id: DeviceID, _ entry: Entry, from listed: [ADBDevice]) -> Bool {
    let serials = Set(listed.map(\.serial))
    return entry.addresses.allSatisfy { !serials.contains($0.endpoint.argument) }
      && !serials.contains { $0.hasPrefix(Self.instancePrefix(id)) }
  }

  /// Holds an address that claims a known device until the user says whether it is.
  func offer(_ endpoint: WirelessEndpoint, as id: DeviceID, named name: String) {
    guard !ignored.contains(endpoint),
      entries[id]?.addresses.contains(where: { $0.endpoint == endpoint }) != true
    else { return }
    unconfirmedAddresses[endpoint] = UnconfirmedAddress(address: endpoint, id: id, name: name)
  }

  // MARK: Connecting

  /// Tries the addresses Ferry may reconnect on its own; an address adb's mDNS lists for the
  /// device is only offered.
  func reconnect(_ id: DeviceID, _ entry: Entry) async -> WirelessOutcome {
    var last = WirelessOutcome.failed(.notRemembered)
    for address in entry.addresses where address.learnt.reconnects {
      last = await attempt(
        address.endpoint, for: Purpose(learnt: address.learnt, expected: id),
        all: [address.endpoint])
      if last.reachedTheDevice { return last }
    }
    guard let services = try? await adb.mdnsServices(),
      let service = services.first(where: { Self.advertises($0, id) })
    else { return last }
    offer(service.endpoint, as: id, named: entry.name)
    return unconfirmedAddresses[service.endpoint] == nil
      ? last : .needsConfirmation(service.endpoint)
  }

  /// Tries each address in turn until one connects, waits for Allow, or waits for the user.
  func firstReached(_ all: [WirelessEndpoint], for purpose: Purpose) async -> WirelessOutcome {
    var last = WirelessOutcome.failed(.notRemembered)
    for endpoint in all {
      last = await attempt(endpoint, for: purpose, all: all)
      if last.reachedTheDevice { return last }
    }
    return last
  }

  /// `adb connect` to one address. What Ferry knows is read first, so a device the connect
  /// itself brings up does not count as known.
  func attempt(
    _ endpoint: WirelessEndpoint, for purpose: Purpose, all: [WirelessEndpoint]
  ) async -> WirelessOutcome {
    let knownBefore = await known().union(entries.keys)
    do throws(ADBError) {
      switch try await adb.connect(endpoint) {
      case .connected(let serial):
        return await adopt(serial, at: endpoint, for: purpose, all: all, known: knownBefore)
      case .awaitingAllow:
        pending[endpoint] = Pending(
          learnt: purpose.learnt, expected: purpose.expected, confirmed: purpose.confirmed,
          addresses: all, known: knownBefore, epoch: forgets)
        log.info("\(endpoint.argument, privacy: .private) waits for Allow on the device")
        return .awaitingAllow(endpoint)
      case .failed(let detail):
        log.info(
          "connecting \(endpoint.argument, privacy: .private) failed: \(detail, privacy: .private)")
        return .failed(.adb(detail))
      }
    } catch {
      return Self.failure(error)
    }
  }

  /// Reads who answers at `adbSerial` and remembers it, unless it answers as another device than
  /// expected, as a device forgotten since `since`, or as a known device at an address the user
  /// has not confirmed: then it is disconnected.
  func adopt(
    _ adbSerial: String, at endpoint: WirelessEndpoint, for purpose: Purpose,
    all: [WirelessEndpoint], known: Set<DeviceID>, since: UInt64? = nil
  ) async -> WirelessOutcome {
    let info: DeviceInfo?
    do throws(ADBError) {
      info = try await adb.device(at: adbSerial)
    } catch {
      log.info("reading \(adbSerial, privacy: .private) failed: \(String(describing: error))")
      return .connected
    }
    guard let info else { return .connected }
    if let expected = purpose.expected, info.id != expected {
      log.error("\(endpoint.argument, privacy: .private) answers as another device")
      await drop(endpoint)
      return .failed(.otherDevice)
    }
    if let since, let forgottenAt = forgotten[info.id], forgottenAt > since {
      log.info("\(endpoint.argument, privacy: .private) answers as a forgotten device")
      await drop(endpoint)
      return .failed(.notRemembered)
    }
    let isNew = entries[info.id]?.addresses.contains { $0.endpoint == endpoint } != true
    let trusted = purpose.learnt == .usb || purpose.confirmed
    if isNew, !trusted, known.union(entries.keys).contains(info.id) {
      log.info("\(endpoint.argument, privacy: .private) claims a known device; asking the user")
      await drop(endpoint)
      offer(endpoint, as: info.id, named: entries[info.id]?.name ?? info.model)
      return .needsConfirmation(endpoint)
    }
    remember(info, at: endpoint, learnt: purpose.learnt, also: purpose.learnt == .usb ? all : [])
    log.info("\(info.id.serial, privacy: .private) connected over the network")
    return .connected
  }

  /// Puts `endpoint` first in the device's entry, with `also` (other addresses read over USB)
  /// after it. An address keeps the stronger of the ways it was learnt.
  func remember(
    _ info: DeviceInfo, at endpoint: WirelessEndpoint, learnt: Learnt, also: [WirelessEndpoint]
  ) {
    let previous = entries[info.id]?.addresses ?? []
    var addresses: [Address] = []
    for candidate in [endpoint] + also + previous.map(\.endpoint)
    where !addresses.contains(where: { $0.endpoint == candidate }) {
      let fresh = candidate == endpoint || also.contains(candidate)
      let kept: Learnt =
        switch previous.first(where: { $0.endpoint == candidate })?.learnt {
        case let before? where !fresh || (before.reconnects && !learnt.reconnects): before
        default: learnt
        }
      addresses.append(Address(endpoint: candidate, learnt: kept))
    }
    let entry = Entry(
      name: entries[info.id]?.name ?? info.model,
      addresses: Array(addresses.prefix(Self.addressLimit)))
    unconfirmedAddresses[endpoint] = nil
    guard entries[info.id] != entry else { return }
    entries[info.id] = entry
    save()
  }

  func drop(_ endpoint: WirelessEndpoint) async {
    do throws(ADBError) {
      try await adb.disconnect(endpoint)
    } catch {
      log.error("disconnecting failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// The adb serial of `id` on USB, if adb serves it there.
  func usbSerial(of id: DeviceID) async throws(ADBError) -> String? {
    let onUSB = try await adb.devices().filter { !$0.isWireless && $0.state == .device }
    if onUSB.contains(where: { $0.serial == id.serial }) { return id.serial }
    for device in onUSB where try await adb.device(at: device.serial)?.id == id {
      return device.serial
    }
    return nil
  }

  /// `tcpip` restarts adbd, which drops off USB for a moment. Connecting before it is back
  /// would serve the unit over the network meanwhile.
  func waitForUSB(_ usb: String) async {
    let deadline = ContinuousClock.now + timing.settle
    repeat {
      let listed = (try? await adb.devices()) ?? []
      if listed.contains(where: { $0.serial == usb && $0.state == .device }) { return }
    } while (try? await Task.sleep(for: timing.poll)) != nil && ContinuousClock.now < deadline
    log.info("\(usb, privacy: .private) did not come back on USB in time")
  }

  /// The paired instance's connect service: the one named by the guid adb printed, or, when it
  /// printed none, the one at the address paired with.
  func connectService(guid: String?, host: String) async -> ADBMDNSService? {
    let deadline = ContinuousClock.now + timing.settle
    repeat {
      let services = (try? await adb.mdnsServices()) ?? []
      if let match = services.first(where: { Self.isConnectService($0, guid: guid, host: host) }) {
        return match
      }
    } while (try? await Task.sleep(for: timing.poll)) != nil && ContinuousClock.now < deadline
    return nil
  }

  static func isConnectService(_ service: ADBMDNSService, guid: String?, host: String) -> Bool {
    service.type == ADBMDNSService.connectType
      && (guid.map { service.name == $0 } ?? (service.endpoint.host == host))
  }

  /// Android names its wireless debugging services `adb-<serial>-<suffix>`.
  static func instancePrefix(_ id: DeviceID) -> String { "adb-\(id.serial)-" }

  static func advertises(_ service: ADBMDNSService, _ id: DeviceID) -> Bool {
    service.type == ADBMDNSService.connectType && service.name.hasPrefix(instancePrefix(id))
  }

  static func failure(_ error: ADBError) -> WirelessOutcome {
    switch error {
    case .serverUnavailable, .adbNotInstalled:
      return .failed(.adbUnavailable)
    case .failed(let detail):
      return .failed(.adb(detail))
    case .deviceGone:
      return .failed(.notOverUSB)
    case .connectionClosed, .protocolViolation, .cancelled, .invalidArgument:
      log.error("adb: \(String(describing: error), privacy: .private)")
      return .failed(.adb(String(describing: error)))
    }
  }

  func save() {
    WirelessStore.save(entries, to: file)
  }
}

extension WirelessOutcome {
  /// The device answered, or the next step is the user's.
  var reachedTheDevice: Bool {
    switch self {
    case .connected, .awaitingAllow, .needsConfirmation: true
    case .needsNetwork, .failed: false
    }
  }
}
