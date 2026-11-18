import DeviceKit
import Foundation
import os

/// The adb serials a device answers on: its USB serial and any `host:port` it is connected at.
public struct ADBRoutes: Sendable, Equatable {
  public let usb: String?
  public let wireless: [String]

  /// The route a session uses: USB while the cable is in.
  var preferred: String? { usb ?? wireless.first }

  var serials: Set<String> { Set(wireless + [usb].compactMap { $0 }) }
}

/// `DeviceTransport` over the user's adb server, for Android devices with USB debugging on.
///
/// The server lists devices by its own serial: the USB serial, or `host:port` over the network.
/// A device is known by its `ro.serialno` instead, read once per adb serial, which is the USB
/// serial MTP reports too, so one device over USB and Wi-Fi (or MTP) is one `DeviceID`. An
/// unauthorised USB device is reported in `notSharing` under its adb serial (its USB serial); an
/// unauthorised network device names no unit until it is allowed, so its `host:port` is passed
/// on in `awaitingAuthorization` instead. An offline device, or one in recovery or the
/// bootloader, is left out.
///
/// A scan touches a device only with `getprop`, over a shell connection of its own, and only for
/// an adb serial it has not seen listed as ready since the server last answered. That includes a
/// held or parked device that went offline or came back with the server; shell commands do not
/// disturb a sync session, so it is still reported without being disturbed. Every answer a scan
/// waits for is bounded by `answerLimit`: a device that does not answer in time (a wedged adbd)
/// is left out of that scan and asked again next time, and a server that does not answer is
/// reported down. Scans take turns; `open`, `park` and `unpark` never wait for one.
///
/// When the server is not answering, a scan reports no usable devices (parked ones stay in
/// `ejected`) and `status` says why. Tracking starts with the transport: the host's tracker
/// starts the server once per outage and `arrivals` ticks when it is back, so devices return
/// without restarting Ferry.
public actor ADBTransport: DeviceTransport {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "ADBTransport")

  /// Ticks on every change adb reports, including the server going away and coming back. Ticks
  /// that arrive faster than they are read coalesce into one, as `USBWatcher`'s do.
  public nonisolated let arrivals: AsyncStream<Void>
  /// What the most recent scan found of adb itself; `nil` until the first scan.
  public private(set) var status: ADBStatus?

  private let host: ADBHost
  private let locator: ADBLocator
  /// Scans take turns, so one never commits what it read over a later one's.
  private let scans = OperationGate()
  private let answerLimit: Duration
  /// Each listed adb serial's device, read from its properties.
  private var named: [String: DeviceInfo] = [:]
  /// The routes of each usable device, as of the most recent scan.
  private var routes: [DeviceID: ADBRoutes] = [:]
  /// Devices with an open (or opening) session, with what `park` needs, recorded at open: the
  /// device may be missing from every scan by the time it is ejected.
  private var held: [DeviceID: Held] = [:]
  /// Devices left alone after an eject, until `unpark(_:)` or until adb has not listed them, in
  /// any state, for `settleTime`.
  private var parked: [DeviceID: Parked] = [:]
  /// What each device was last seen as, so a device parked after its session ended (or never
  /// opened) is still reported by name and recognised under its adb serials.
  private var lastKnown: [DeviceID: Held] = [:]
  /// How many scans in a row each listed adb serial has stayed unnamed.
  private var unnamedTries: [String: Int] = [:]
  private let now: @Sendable () -> ContinuousClock.Instant

  private struct Held {
    let info: DeviceInfo
    let serials: Set<String>
  }

  private struct Parked {
    var info: DeviceInfo
    /// The adb serials it has been reached at.
    var serials: Set<String>
    /// When a scan first found none of them listed, if none has been listed since.
    var missingSince: ContinuousClock.Instant?
  }

  public init(port: UInt16 = 5037, locator: ADBLocator = ADBLocator()) {
    self.init(host: ADBHost(port: port, locator: locator), locator: locator)
  }

  /// How long a parked device must be missing from adb's list to count as unplugged. A
  /// restarted server lists a USB device only after it has re-enumerated, and a Wi-Fi device
  /// can drop out briefly; a person unplugging and replugging takes longer.
  static let settleTime = Duration.seconds(5)

  /// How long a scan or an open waits for the server or a device to answer. `getprop` answers in
  /// tens of milliseconds over USB and well under a second over Wi-Fi; three seconds leaves a
  /// wide margin for a slow link. Devices are read at once, so a scan waits about one limit for
  /// the list and one for names, however many devices are wedged.
  static let defaultAnswerLimit = Duration.seconds(3)

  /// When to scan again for a listed device that could not be named. adb sends no event for a
  /// list that has not changed, so a slow but healthy device (a Wi-Fi device waking up) would
  /// otherwise wait for some unrelated change. Two seconds gives it a quick second chance;
  /// doubling to thirty keeps a wedged device, which costs a scan `answerLimit` each time, from
  /// keeping the hub scanning.
  static let unnamedRetry = Duration.seconds(2)
  static let unnamedRetryLimit = Duration.seconds(30)

  static func unnamedDelay(afterTries tries: Int) -> Duration {
    var delay = unnamedRetry
    for _ in 1..<max(tries, 1) where delay < unnamedRetryLimit { delay *= 2 }
    return min(delay, unnamedRetryLimit)
  }

  init(
    host: ADBHost, locator: ADBLocator, answerLimit: Duration = defaultAnswerLimit,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.host = host
    self.locator = locator
    self.answerLimit = answerLimit
    self.now = now
    let lists = host.trackDevices()
    arrivals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let relay = Task {
        for await _ in lists { continuation.yield() }
        continuation.finish()
      }
      continuation.onTermination = { _ in relay.cancel() }
    }
  }

  /// Where the adb server reaches `id`, as of the most recent scan.
  public func routes(for id: DeviceID) -> ADBRoutes? { routes[id] }

  public func scan() async throws(TransportError) -> DeviceScan {
    try await scans.run { () async throws(TransportError) -> DeviceScan in
      let listed: [ADBDevice]
      do throws(ADBError) {
        listed = try await Self.within(answerLimit) { [host] () async throws(ADBError) in
          try await host.devices()
        }
      } catch .cancelled {
        throw .cancelled
      } catch {
        serverUnreachable(error)
        return DeviceScan(
          devices: [], ejected: parked.values.map(\.info).sorted(by: Self.serial), method: .usbADB,
          adbStatus: status)
      }
      status = .available
      let usable = listed.filter { $0.state == .device }
      let serials = Set(usable.map(\.serial))
      // An address can belong to another device next time: forget what is not listed.
      named = named.filter { serials.contains($0.key) }
      let unnamed = usable.map(\.serial).filter { named[$0] == nil }
      named.merge(try await read(unnamed)) { _, new in new }
      let stillUnnamed = usable.map(\.serial).filter { named[$0] == nil }
      unnamedTries = Dictionary(
        uniqueKeysWithValues: stillUnnamed.map { ($0, (unnamedTries[$0] ?? 0) + 1) })
      let retry = unnamedTries.values.max().map { Self.unnamedDelay(afterTries: $0) }
      // Every serial adb lists on a cable, in any state. A network route never serves one: a
      // serial alone does not prove a network device is the unit on the cable.
      let onUSB = Set(listed.filter { !$0.isWireless }.map { DeviceID(serial: $0.serial) })
      let found = assemble(usable).filter { $0.value.usb != nil || !onUSB.contains($0.key) }
      routes = found.mapValues { ADBRoutes(usb: $0.usb, wireless: $0.wireless.sorted()) }
      for (id, device) in found {
        lastKnown[id] = Held(
          info: device.info, serials: Set(device.wireless + [device.usb].compactMap { $0 }))
      }
      let settle = settleParked(found: found, listed: Set(listed.map(\.serial)))
      let rescanAfter = [settle, retry].compactMap { $0 }.min()
      let known = Set(found.keys).union(parked.keys)
      let unauthorized = listed.filter { $0.state == .unauthorized }
        .filter { !known.contains(Self.describe($0).id) }
        .sorted { $0.serial < $1.serial }
      let overNetwork = found.filter { $0.value.usb == nil }.keys
      return DeviceScan(
        devices: found.values.map(\.info).filter { parked[$0.id] == nil }.sorted(by: Self.serial),
        notSharing: unauthorized.filter { !$0.isWireless }.map(Self.describe),
        ejected: parked.values.map(\.info).sorted(by: Self.serial), rescanAfter: rescanAfter,
        method: .usbADB,
        methods: Dictionary(uniqueKeysWithValues: overNetwork.map { ($0, .wifiADB) }),
        awaitingAuthorization: unauthorized.filter(\.isWireless).map(\.serial),
        presentOverUSB: onUSB.union(found.filter { $0.value.usb != nil }.keys),
        adbStatus: .available,
        awaitingUSBDebugging: Self.waitingForAllow(listed))
    }
  }

  /// The devices adb lists over USB as unauthorised: USB debugging is on, the user has not
  /// allowed this Mac yet.
  private static func waitingForAllow(_ listed: [ADBDevice]) -> Set<DeviceID> {
    Set(
      listed.filter { $0.state == .unauthorized && !$0.isWireless }
        .map { describe($0).id })
  }

  /// Looks for `adb` again and starts its server, which the user may have just installed. A
  /// missing `adb` is no error: the next scan reports `.notInstalled`.
  public func startADBServer() async {
    do throws(ADBError) {
      try await host.startServer()
    } catch {
      Self.log.info("starting adb: \(String(describing: error), privacy: .public)")
    }
  }

  /// The named devices among `usable`, one per `ro.serialno`, USB first for info and route.
  private func assemble(_ usable: [ADBDevice]) -> [DeviceID: Found] {
    var found: [DeviceID: Found] = [:]
    for device in usable {
      guard let info = named[device.serial] else { continue }
      var entry = found[info.id] ?? Found(info: info)
      if device.isWireless {
        entry.wireless.append(device.serial)
      } else {
        entry.usb = device.serial
        entry.info = info
      }
      found[info.id] = entry
    }
    return found
  }

  /// One device as a scan assembles it from its adb serials.
  private struct Found {
    var info: DeviceInfo
    var usb: String?
    var wireless: [String] = []
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    if held[id] != nil { throw .deviceBusy }
    guard parked[id] == nil, let routes = routes[id], let serial = routes.preferred,
      let info = named[serial]
    else { throw .deviceNotFound(id) }
    // Held from here, so a second open while this one waits is busy.
    held[id] = Held(info: info, serials: routes.serials)
    let features: Set<String>
    do throws(ADBError) {
      features = try await Self.within(answerLimit) { [host] () async throws(ADBError) in
        try await host.features(serial)
      }
    } catch {
      held[id] = nil
      if error == .cancelled { throw .cancelled }
      // Gone since the scan, or the server with it: the next scan says which.
      Self.log.info("not opening \(serial, privacy: .private): \(String(describing: error))")
      throw .deviceNotFound(id)
    }
    return ADBSession(
      host: host, serial: serial, info: info, features: features,
      method: routes.usb == nil ? .wifiADB : .usbADB,
      onRelease: { [weak self] in await self?.release(id) })
  }

  /// Parks from the hold, not the last scan, which may not list the device at all (offline, or
  /// the server down) when the user ejects it. Without a hold, from what was last seen of it.
  public func park(_ id: DeviceID) async {
    // A session that has already ended (its device dropped) leaves no hold; the eject still
    // stands, by what was last known of the device.
    let known =
      held[id] ?? lastKnown[id]
      ?? Held(
        info: DeviceInfo(id: id, manufacturer: "Unknown", model: "Android device"), serials: [])
    parked[id] = Parked(info: known.info, serials: known.serials)
  }

  public func unpark(_ id: DeviceID) async {
    parked[id] = nil
  }

  private func release(_ id: DeviceID) {
    held[id] = nil
  }

  /// Records why the server could not be used. Its devices may come back under other
  /// addresses, so what was learnt of them is dropped; parked devices stay parked.
  private func serverUnreachable(_ error: ADBError) {
    named = [:]
    routes = [:]
    // Whether a parked device is still attached is unknown until the server answers again.
    for id in parked.keys { parked[id]?.missingSince = nil }
    if error == .serverUnavailable {
      status = locator.adbURL() == nil ? .notInstalled : .serverDown
    } else {
      status = .serverDown
      Self.log.error("listing adb devices failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Keeps a parked device parked while adb lists it under any of its serials, in any state
  /// (a restarted server shows a USB device as offline before it is ready), and lets it go once
  /// it has been missing for `settleTime`. Returns how long until the soonest missing one
  /// settles, so the hub scans again without waiting for adb.
  private func settleParked(found: [DeviceID: Found], listed: Set<String>) -> Duration? {
    let now = now()
    var soonest: Duration?
    for (id, var entry) in parked {
      if let device = found[id] {
        entry.info = device.info
        entry.serials.formUnion(device.wireless + [device.usb].compactMap { $0 })
      }
      if found[id] != nil || !entry.serials.isDisjoint(with: listed) {
        entry.missingSince = nil
        parked[id] = entry
        continue
      }
      let since = entry.missingSince ?? now
      let gone = since.duration(to: now)
      guard gone < Self.settleTime else {
        parked[id] = nil
        continue
      }
      entry.missingSince = since
      parked[id] = entry
      soonest = min(soonest ?? Self.settleTime, Self.settleTime - gone)
    }
    return soonest
  }

  private static func serial(_ lhs: DeviceInfo, _ rhs: DeviceInfo) -> Bool {
    lhs.id.serial < rhs.id.serial
  }

  /// Reads the devices behind `serials` from their properties, all at once, each bounded by
  /// `answerLimit`. One whose serial cannot be read in time is left out, uncached, and asked
  /// again next scan; a cancelled scan throws.
  private func read(_ serials: [String]) async throws(TransportError) -> [String: DeviceInfo] {
    let limit = answerLimit
    let results = await withTaskGroup(of: (String, Result<DeviceInfo?, ADBError>).self) { group in
      for serial in serials {
        group.addTask { [host] in
          do throws(ADBError) {
            return (
              serial,
              .success(
                try await Self.within(limit) { () async throws(ADBError) in
                  try await Self.info(of: serial, on: host)
                })
            )
          } catch {
            return (serial, .failure(error))
          }
        }
      }
      var results: [(String, Result<DeviceInfo?, ADBError>)] = []
      for await result in group { results.append(result) }
      return results
    }
    if Task.isCancelled { throw .cancelled }
    var named: [String: DeviceInfo] = [:]
    for (serial, result) in results {
      switch result {
      case .success(let info?):
        named[serial] = info
      case .success(nil):
        Self.log.info("\(serial, privacy: .private) reports no ro.serialno; leaving it out")
      case .failure(let error):
        Self.log.info(
          "reading \(serial, privacy: .private) failed: \(String(describing: error), privacy: .public)"
        )
      }
    }
    return named
  }
}
