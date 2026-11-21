import DeviceKit
import Foundation
import os

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
  static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "ADBTransport")

  /// Ticks on every change adb reports, including the server going away and coming back. Ticks
  /// that arrive faster than they are read coalesce into one, as `USBWatcher`'s do.
  public nonisolated let arrivals: AsyncStream<Void>
  /// What the most recent scan found of adb itself; `nil` until the first scan.
  public private(set) var status: ADBStatus?

  let host: ADBHost
  private let locator: ADBLocator
  /// Scans take turns, so one never commits what it read over a later one's.
  private let scans = OperationGate()
  private let answerLimit: Duration
  /// What `answerLimit` is measured on.
  private let clock: any Clock<Duration>
  private let serving: ADBNetworkPolicy
  private let opened: ADBOpenHandler
  /// Each listed connection's device, read from its properties.
  private var named: [Listing: DeviceInfo] = [:]
  /// The routes of each usable device, as of the most recent scan.
  private var routes: [DeviceID: ADBRoutes] = [:]
  /// The server's connection (`transport_id`) behind each listed adb serial, as of the most
  /// recent scan; absent where adb does not report one.
  var transportIDs: [String: String] = [:]
  /// Devices with an open (or opening) session, with what `park` needs, recorded at open: the
  /// device may be missing from every scan by the time it is ejected.
  var held: [DeviceID: Held] = [:]
  /// Devices left alone after an eject, until `unpark(_:)` or until adb has not listed them, in
  /// any state, for `settleTime`.
  private var parked: [DeviceID: Parked] = [:]
  /// What each device was last seen as, so a device parked after its session ended (or never
  /// opened) is still reported by name and recognised under its adb serials.
  private var lastKnown: [DeviceID: Held] = [:]
  /// How many scans in a row each listed connection has stayed unnamed.
  private var unnamedTries: [Listing: Int] = [:]
  private let now: @Sendable () -> ContinuousClock.Instant

  struct Held {
    let info: DeviceInfo
    let serials: Set<String>
    /// The adb serial the session was opened on, once it is open; `nil` while it opens and for
    /// what was last seen of a device.
    var route: String?
    /// The server's connection to the unit when the session opened (`transport_id`), if adb
    /// reports one: the session and its tool route select the unit by it.
    var transportID: String?
  }

  private struct Parked {
    var info: DeviceInfo
    /// The adb serials it has been reached at.
    var serials: Set<String>
    /// When a scan first found none of them listed, if none has been listed since.
    var missingSince: ContinuousClock.Instant?
  }

  /// `serving` decides which network routes serve their device; USB routes always do. `opened`
  /// hears of each session as it opens.
  public init(
    port: UInt16 = 5037, locator: ADBLocator = ADBLocator(), keeper: ADBServerKeeper,
    serving: @escaping ADBNetworkPolicy = { _, _ in true },
    opened: @escaping ADBOpenHandler = { _, _, _ in }
  ) {
    self.init(
      host: ADBHost(port: port, locator: locator, keeper: keeper), locator: locator,
      serving: serving,
      opened: opened)
  }

  /// How long a parked device must be missing from adb's list to count as unplugged. A
  /// restarted server lists a USB device only after it has re-enumerated, and a Wi-Fi device
  /// can drop out briefly; a person unplugging and replugging takes longer.
  static let settleTime = Duration.seconds(5)

  /// How long a scan or an open waits for the server or a device to answer. `getprop` answers in
  /// tens of milliseconds over USB and well under a second over Wi-Fi; three seconds leaves a
  /// wide margin for a slow link. Devices are read at once, so a scan waits about one limit for
  /// the list and one for names, however many devices are wedged.
  public static let defaultAnswerLimit = Duration.seconds(3)

  /// When to scan again for a listed device that could not be named. adb sends no event for a
  /// list that has not changed, so a slow but healthy device (a Wi-Fi device waking up) would
  /// otherwise wait for some unrelated change. Two seconds gives it a quick second chance;
  /// doubling to thirty keeps a wedged device, which costs a scan `answerLimit` each time, from
  /// keeping the hub scanning.
  static let unnamedRetry = Duration.seconds(2)
  static let unnamedRetryLimit = Duration.seconds(30)

  init(
    host: ADBHost, locator: ADBLocator, answerLimit: Duration = defaultAnswerLimit,
    clock: any Clock<Duration> = ContinuousClock(),
    serving: @escaping ADBNetworkPolicy = { _, _ in true },
    opened: @escaping ADBOpenHandler = { _, _, _ in },
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.host = host
    self.serving = serving
    self.opened = opened
    self.locator = locator
    self.answerLimit = answerLimit
    self.clock = clock
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

  public func scan() async throws(TransportError) -> DeviceScan {
    try await scans.run { () async throws(TransportError) -> DeviceScan in
      let listed: [ADBDevice]
      do throws(ADBError) {
        listed = try await Self.within(answerLimit, on: clock) { [host] () async throws(ADBError) in
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
      let listings = Set(usable.map(Listing.init))
      // An address can belong to another device next time: forget what is not listed.
      named = named.filter { listings.contains($0.key) }
      let unnamed = listings.filter { named[$0] == nil }
      named.merge(try await readNames(unnamed)) { _, new in new }
      let stillUnnamed = listings.filter { named[$0] == nil }
      unnamedTries = Dictionary(
        uniqueKeysWithValues: stillUnnamed.map { ($0, (unnamedTries[$0] ?? 0) + 1) })
      let retry = unnamedTries.values.max().map { Self.unnamedDelay(afterTries: $0) }
      // Every serial adb lists on a cable, in any state. A network route never serves one: a
      // serial alone does not prove a network device is the unit on the cable.
      let onUSB = Set(listed.filter { !$0.isWireless }.map { DeviceID(serial: $0.serial) })
      let found = assemble(usable).filter { $0.value.usb != nil || !onUSB.contains($0.key) }
      routes = found.mapValues { ADBRoutes(usb: $0.usb, wireless: $0.wireless.sorted()) }
      noteTransports(listed)
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

  /// The named devices among `usable`, one per `ro.serialno`, USB first for info and route. A
  /// network route the policy refuses is left out.
  private func assemble(_ usable: [ADBDevice]) -> [DeviceID: Found] {
    var found: [DeviceID: Found] = [:]
    for device in usable {
      guard let info = named[Listing(device)],
        !device.isWireless || serving(device.serial, info.id)
      else { continue }
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
      let info = named.first(where: { $0.key.serial == serial })?.value
    else { throw .deviceNotFound(id) }
    // Held from here, so a second open while this one waits is busy. The session, and the
    // open itself, select the unit by the connection the scan saw, so neither can reach a unit
    // that took the address since.
    let transportID = transportIDs[serial]
    held[id] = Held(info: info, serials: routes.serials, transportID: transportID)
    let features: Set<String>
    do throws(ADBError) {
      features = try await Self.within(answerLimit, on: clock) { [host] () async throws(ADBError) in
        try await host.features(serial, transportID: transportID)
      }
    } catch {
      release(id)
      if error == .cancelled { throw .cancelled }
      // Gone since the scan, or the server with it: the next scan says which.
      Self.log.info(
        "not opening \(serial, privacy: .private): \(String(describing: error), privacy: .private)")
      throw .deviceNotFound(id)
    }
    // Ejected while the device answered: no session for it.
    guard parked[id] == nil else {
      release(id)
      throw .deviceNotFound(id)
    }
    // Only now is there a session for the tools to follow.
    held[id]?.route = serial
    if transportID == nil {
      Self.log.info(
        "adb lists no connection id for \(serial, privacy: .private); its session and tools use the serial"
      )
    }
    opened(id, ADBRoute(serial: serial, transportID: transportID), deviceTools)
    return ADBSession(
      host: host, serial: serial, transportID: transportID, info: info, features: features,
      method: routes.usb == nil ? .wifiADB : .usbADB, clock: clock,
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
      Self.log.error("listing adb devices failed: \(String(describing: error), privacy: .private)")
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

}

extension ADBTransport {
  /// Reads the devices behind `listings`, each within the answer limit.
  private func readNames(_ listings: Set<Listing>) async throws(TransportError)
    -> [Listing: DeviceInfo]
  {
    try await Self.read(listings, on: host, within: answerLimit, clock: clock)
  }

  /// How long to wait before scanning again for a device that stayed unnamed `tries` scans.
  static func unnamedDelay(afterTries tries: Int) -> Duration {
    var delay = unnamedRetry
    for _ in 1..<max(tries, 1) where delay < unnamedRetryLimit { delay *= 2 }
    return min(delay, unnamedRetryLimit)
  }

  /// Where the adb server reaches `id`, as of the most recent scan.
  public func routes(for id: DeviceID) -> ADBRoutes? { routes[id] }

  /// The adb serial of `id`'s open session, until that session ends, whatever later scans
  /// find: a network route the policy stops serving still carries the session open on it.
  public func sessionRoute(for id: DeviceID) -> ADBRoute? {
    held[id].flatMap { entry in
      entry.route.map { ADBRoute(serial: $0, transportID: entry.transportID) }
    }
  }

  /// The tools (APK install, screenshot, screen recording) over this transport's server.
  public nonisolated var deviceTools: ADBDeviceTools { ADBDeviceTools(host: host) }

  /// The devices adb lists over USB as unauthorised: USB debugging is on, the user has not
  /// allowed this Mac yet.
  private static func waitingForAllow(_ listed: [ADBDevice]) -> Set<DeviceID> {
    Set(
      listed.filter { $0.state == .unauthorized && !$0.isWireless }
        .map { describe($0).id })
  }

  /// Looks for `adb` again and starts its server: Ferry may have just fetched it, or the user
  /// installed it. A missing `adb` is no error: the next scan reports `.notInstalled`.
  public func startADBServer() async {
    do throws(ADBError) {
      try await host.startServer()
    } catch {
      Self.log.log(
        level: Self.startFailureLevel(error),
        "starting adb: \(String(describing: error), privacy: .private)")
    }
  }

  /// A missing `adb` is a state the menu already shows; any other failure to start is a problem.
  static func startFailureLevel(_ error: ADBError) -> OSLogType {
    error == .adbNotInstalled ? .info : .error
  }
}
