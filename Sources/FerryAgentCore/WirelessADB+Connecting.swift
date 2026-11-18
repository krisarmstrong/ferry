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
        guard reconnectDue, reconnecting == nil else { continue }
        reconnectDue = false
        reconnecting = Task { await self.reconnectMissing(listed) }
      }
    }
  }

  func pollMDNS() async {
    while (try? await Task.sleep(for: timing.mdnsInterval)) != nil {
      await gate.run { await offerFromMDNS() }
    }
  }

  /// Adopts each waiting address adb now lists as allowed, checked against what Ferry knows
  /// now as well as when the connect started, unless the device it answers as was forgotten
  /// since. The address stays unserved until that is decided.
  func resolvePending(_ listed: [ADBDevice]) async {
    let allowed = Set(listed.filter { $0.state == .device }.map(\.serial))
    for (endpoint, waiting) in pending where allowed.contains(endpoint.argument) {
      pending[endpoint] = nil
      _ = await adopt(
        endpoint.argument, at: endpoint,
        for: Purpose(
          learnt: waiting.learnt, expected: waiting.expected, confirmed: waiting.confirmed),
        all: waiting.addresses, basis: Basis(known: waiting.known, epoch: waiting.epoch))
      vouching.settle(endpoint.argument)
    }
  }

  /// Reconnects the remembered devices adb does not list, a few at a time and outside the gate,
  /// so a user's request never waits behind addresses that do not answer.
  /// A device forgotten after the list was taken is skipped, and is not adopted if it answers.
  func reconnectMissing(_ listed: [ADBDevice]) async {
    let since = forgets
    var due = entries.filter { isMissing($0.key, $0.value, from: listed) }.makeIterator()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<Self.reconnectLimit {
        guard let (id, entry) = due.next() else { break }
        group.addTask { _ = await self.reconnect(id, entry, since: since) }
      }
      while await group.next() != nil {
        guard let (id, entry) = due.next() else { continue }
        group.addTask { _ = await self.reconnect(id, entry, since: since) }
      }
    }
    reconnecting = nil
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

  /// Holds an address that claims a known device until the user says whether it is. An address
  /// already offered as another device is trusted as neither: its offer is dropped. Returns
  /// whether the address is on offer.
  @discardableResult
  func offer(_ endpoint: WirelessEndpoint, as id: DeviceID, named name: String) -> Bool {
    guard !ignored.contains(endpoint),
      entries[id]?.addresses.contains(where: { $0.endpoint == endpoint }) != true
    else { return false }
    if let existing = unconfirmedAddresses[endpoint], existing.id != id {
      log.error("\(endpoint.argument, privacy: .private) claimed two devices; ignoring it")
      unconfirmedAddresses[endpoint] = nil
      ignored.insert(endpoint)
      return false
    }
    unconfirmedAddresses[endpoint] = UnconfirmedAddress(address: endpoint, id: id, name: name)
    return true
  }

  // MARK: Connecting

  /// Tries the addresses Ferry may reconnect on its own; an address adb's mDNS lists for the
  /// device is only offered.
  /// An address the device no longer has (forgotten meanwhile) is not tried.
  func reconnect(_ id: DeviceID, _ entry: Entry, since: UInt64? = nil) async -> WirelessOutcome {
    var last = WirelessOutcome.failed(.notRemembered)
    for address in entry.addresses where address.learnt.reconnects {
      guard entries[id]?.addresses.contains(address) == true else { continue }
      last = await attempt(
        address.endpoint, for: Purpose(learnt: address.learnt, expected: id, since: since),
        all: [address.endpoint])
      if last.reachedTheDevice { return last }
    }
    // Forgotten meanwhile: nothing more is done for it, not even an offer.
    guard entries[id] != nil, let services = try? await adb.mdnsServices(),
      let service = services.first(where: { Self.advertises($0, id) }), entries[id] != nil
    else { return last }
    return offer(service.endpoint, as: id, named: entry.name)
      ? .needsConfirmation(service.endpoint) : last
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

  /// `adb connect` to one address. The address is not served while this decides (nor while it
  /// waits for Allow). What Ferry knows, and the count of forgets, are read first, so neither the
  /// device the connect itself brings up nor a forget meanwhile is missed.
  func attempt(
    _ endpoint: WirelessEndpoint, for purpose: Purpose, all: [WirelessEndpoint]
  ) async -> WirelessOutcome {
    vouching.unsettle(endpoint.argument)
    var holding = false
    defer { if !holding { vouching.settle(endpoint.argument) } }
    let epoch = purpose.since ?? forgets
    let knownBefore = await knownNames()
    do throws(ADBError) {
      switch try await adb.connect(endpoint) {
      case .connected(let serial):
        return await adopt(
          serial, at: endpoint, for: purpose, all: all,
          basis: Basis(known: knownBefore, epoch: epoch))
      case .awaitingAllow:
        // One hold per waiting address, released once when it resolves or is forgotten.
        holding = pending[endpoint] == nil
        pending[endpoint] = Pending(
          learnt: purpose.learnt, expected: purpose.expected, confirmed: purpose.confirmed,
          addresses: all, known: knownBefore, epoch: epoch)
        log.info("\(endpoint.argument, privacy: .private) waits for Allow on the device")
        return .awaitingAllow(endpoint)
      case .failed(let detail):
        log.info(
          "connecting \(endpoint.argument, privacy: .private) failed: \(detail, privacy: .private)")
        // adb can keep a connection it could not use (offline, or listed in another form).
        await drop(endpoint)
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
    all: [WirelessEndpoint], basis: Basis
  ) async -> WirelessOutcome {
    // Fails closed: a device that does not say who it is is not kept connected.
    let read: DeviceInfo?
    do throws(ADBError) {
      read = try await adb.device(at: adbSerial)
    } catch {
      log.info("reading \(adbSerial, privacy: .private) failed: \(String(describing: error))")
      read = nil
    }
    guard let info = read else {
      await drop(endpoint)
      return .failed(.unidentified)
    }
    let (known, since) = (basis.known, basis.epoch)
    if let expected = purpose.expected, info.id != expected {
      log.error("\(endpoint.argument, privacy: .private) answers as another device")
      await drop(endpoint)
      return .failed(.otherDevice)
    }
    let isNew = entries[info.id]?.addresses.contains { $0.endpoint == endpoint } != true
    let trusted = purpose.learnt == .usb || purpose.confirmed
    let knownNow = await knownNames().merging(known) { now, _ in now }
    // After the last suspension: a forget that ran meanwhile wins.
    if let forgottenAt = forgotten[info.id], forgottenAt > since {
      log.info("\(endpoint.argument, privacy: .private) answers as a forgotten device")
      await drop(endpoint)
      return .failed(.notRemembered)
    }
    // Known now or when the connect began: the hub cannot be serving this address meanwhile,
    // since it is unsettled, so any route it serves the device by is another one.
    if isNew, !trusted, let name = knownNow[info.id] {
      log.info("\(endpoint.argument, privacy: .private) claims a known device; asking the user")
      await drop(endpoint)
      let offered = offer(endpoint, as: info.id, named: name)
      return offered ? .needsConfirmation(endpoint) : .failed(.otherDevice)
    }
    remember(info, at: endpoint, learnt: purpose.learnt, also: purpose.learnt == .usb ? all : [])
    log.info("\(info.id.serial, privacy: .private) connected over the network")
    return .connected
  }

  /// Puts `endpoint` first in the device's entry, with `also` after it: the unit's other
  /// addresses, read from it over USB. Only `endpoint` has answered as the device so far; each of
  /// the others must when it is reconnected, or it is dropped then. An address keeps the stronger
  /// of the ways it was learnt.
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

  /// The paired instance's connect service at the host paired with: Android advertises both
  /// services from one address, and mDNS can be spoofed, so a service of the right name at any
  /// other host is not the device the code was checked with. Named by the guid adb printed, when
  /// it printed one.
  func connectService(guid: String?, pairedAt pairing: WirelessEndpoint) async -> ADBMDNSService? {
    let deadline = ContinuousClock.now + timing.settle
    repeat {
      let services = (try? await adb.mdnsServices()) ?? []
      if let match = services.first(where: {
        Self.isConnectService($0, guid: guid, pairedAt: pairing)
      }) {
        return match
      }
    } while (try? await Task.sleep(for: timing.poll)) != nil && ContinuousClock.now < deadline
    return nil
  }

  static func isConnectService(
    _ service: ADBMDNSService, guid: String?, pairedAt pairing: WirelessEndpoint
  ) -> Bool {
    service.type == ADBMDNSService.connectType && service.endpoint.isSameHost(as: pairing)
      && guid.map { service.name == $0 } != false
  }

  /// The devices Ferry knows now, the hub's and the remembered, by the name Ferry has for each.
  func knownNames() async -> [DeviceID: String] {
    var names = await known()
    for (id, entry) in entries { names[id] = entry.name }
    return names
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
    vouching.remember(entries)
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
