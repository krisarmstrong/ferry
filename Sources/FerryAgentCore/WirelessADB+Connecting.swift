import ADBTransport
import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

/// Following adb's server, and the connecting every request and reconnect shares.
extension WirelessADB {
  // MARK: Following adb

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
      await gate.run { await reconnectFromMDNS() }
    }
  }

  /// Remembers each waiting address adb now lists as allowed.
  func resolvePending(_ listed: [ADBDevice]) async {
    let allowed = Set(listed.filter { $0.state == .device }.map(\.serial))
    for (endpoint, waiting) in pending where allowed.contains(endpoint.argument) {
      pending[endpoint] = nil
      _ = await adopt(
        endpoint.argument, at: endpoint, method: waiting.method, expected: waiting.expected,
        all: waiting.addresses)
    }
  }

  func reconnectMissing(_ listed: [ADBDevice]) async {
    for (id, entry) in entries where isMissing(id, entry, from: listed) {
      _ = await reconnect(id, entry)
    }
  }

  /// Reads adb's mDNS only while a remembered device is missing, and connects only to a connect
  /// service named for that device's serial.
  func reconnectFromMDNS() async {
    guard let listed = try? await adb.devices() else { return }
    let missing = entries.filter { isMissing($0.key, $0.value, from: listed) }
    guard !missing.isEmpty, let services = try? await adb.mdnsServices() else { return }
    for (id, entry) in missing {
      guard let service = services.first(where: { Self.advertises($0, id) }) else { continue }
      _ = await attempt(
        service.endpoint, method: entry.method, expected: id,
        all: [service.endpoint] + entry.addresses)
    }
  }

  /// adb lists none of its addresses, and no mDNS connection named for it.
  func isMissing(_ id: DeviceID, _ entry: Entry, from listed: [ADBDevice]) -> Bool {
    let serials = Set(listed.map(\.serial))
    return entry.addresses.allSatisfy { !serials.contains($0.argument) }
      && !serials.contains { $0.hasPrefix(Self.instancePrefix(id)) }
  }

  // MARK: Connecting

  func reconnect(_ id: DeviceID, _ entry: Entry) async -> WirelessOutcome {
    let outcome = await firstReached(entry.addresses, method: entry.method, expected: id)
    if case .connected = outcome { return outcome }
    if case .awaitingAllow = outcome { return outcome }
    guard let services = try? await adb.mdnsServices(),
      let service = services.first(where: { Self.advertises($0, id) })
    else { return entry.addresses.isEmpty ? .failed(.notRemembered) : outcome }
    return await attempt(
      service.endpoint, method: entry.method, expected: id,
      all: [service.endpoint] + entry.addresses)
  }

  /// Tries each address in turn until one connects or waits for Allow.
  func firstReached(
    _ endpoints: [WirelessEndpoint], method: Method, expected: DeviceID
  ) async -> WirelessOutcome {
    var last = WirelessOutcome.failed(.notRemembered)
    for endpoint in endpoints {
      last = await attempt(endpoint, method: method, expected: expected, all: endpoints)
      switch last {
      case .connected, .awaitingAllow: return last
      case .needsNetwork, .failed: continue
      }
    }
    return last
  }

  /// `adb connect` to one address. `expected`, when known, is the device it must answer as.
  func attempt(
    _ endpoint: WirelessEndpoint, method: Method, expected: DeviceID?, all: [WirelessEndpoint]
  ) async -> WirelessOutcome {
    do throws(ADBError) {
      switch try await adb.connect(endpoint) {
      case .connected(let serial):
        return await adopt(serial, at: endpoint, method: method, expected: expected, all: all)
      case .awaitingAllow:
        pending[endpoint] = Pending(method: method, expected: expected, addresses: all)
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

  /// Reads who answers at `adbSerial` and remembers it, or disconnects an address that answers
  /// as another device than `expected`.
  func adopt(
    _ adbSerial: String, at endpoint: WirelessEndpoint, method: Method, expected: DeviceID?,
    all: [WirelessEndpoint]
  ) async -> WirelessOutcome {
    let info: DeviceInfo?
    do throws(ADBError) {
      info = try await adb.device(at: adbSerial)
    } catch {
      log.info("reading \(adbSerial, privacy: .private) failed: \(String(describing: error))")
      return .connected
    }
    guard let info else { return .connected }
    if let expected, info.id != expected {
      log.error("\(endpoint.argument, privacy: .private) answers as another device; disconnecting")
      do throws(ADBError) {
        try await adb.disconnect(endpoint)
      } catch {
        log.error("disconnecting failed: \(String(describing: error), privacy: .private)")
      }
      return .failed(.otherDevice)
    }
    var addresses: [WirelessEndpoint] = []
    for address in [endpoint] + all + (entries[info.id]?.addresses ?? [])
    where !addresses.contains(address) {
      addresses.append(address)
    }
    let entry = Entry(
      name: info.model, method: method, addresses: Array(addresses.prefix(Self.addressLimit)))
    if entries[info.id] != entry {
      entries[info.id] = entry
      save()
    }
    log.info("\(info.id.serial, privacy: .private) connected over the network")
    return .connected
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
