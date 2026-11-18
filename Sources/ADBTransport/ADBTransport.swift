import DeviceKit
import Foundation
import os

/// Whether adb can be used, for the menu to show.
public enum ADBStatus: Sendable, Equatable {
  case available
  /// No `adb` in any of the places Ferry looks, and no server answering.
  case notInstalled
  /// `adb` is installed but its server is not answering.
  case serverDown
}

/// The adb serials a device answers on: its USB serial and any `host:port` it is connected at.
public struct ADBRoutes: Sendable, Equatable {
  public let usb: String?
  public let wireless: [String]

  /// The route a session uses: USB while the cable is in.
  var preferred: String? { usb ?? wireless.first }
}

/// `DeviceTransport` over the user's adb server, for Android devices with USB debugging on.
///
/// The server lists devices by its own serial: the USB serial, or `host:port` over the network.
/// A device is known by its `ro.serialno` instead, read once per adb serial, which is the USB
/// serial MTP reports too, so one device over USB and Wi-Fi (or MTP) is one `DeviceID`. An
/// unauthorised device is reported in `notSharing` under its adb serial; an offline one, or one
/// in recovery or the bootloader, is left out. A scan reads a device's properties only for an adb
/// serial it has not seen listed since the server last answered, and never opens a sync session,
/// so a held device is reported without disturbing it. When the server is not answering, a scan
/// reports nothing and `status` says why; `arrivals` ticks when the server comes back (the
/// host's tracker starts it once per outage), so devices return without restarting Ferry.
public actor ADBTransport: DeviceTransport {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "ADBTransport")

  /// Ticks on every change adb reports, including the server going away and coming back. Ticks
  /// that arrive faster than they are read coalesce into one, as `USBWatcher`'s do.
  public nonisolated let arrivals: AsyncStream<Void>
  /// What the most recent scan found of adb itself.
  public private(set) var status: ADBStatus = .available

  private let host: ADBHost
  private let locator: ADBLocator
  private let gate = OperationGate()
  /// Each listed adb serial's device, read from its properties.
  private var named: [String: DeviceInfo] = [:]
  /// The routes of each usable device, as of the most recent scan.
  private var routes: [DeviceID: ADBRoutes] = [:]
  /// Devices with an open session.
  private var held: Set<DeviceID> = []
  /// Devices left alone after an eject, until `unpark(_:)` or until adb has not listed them, in
  /// any state, for `settleTime`.
  private var parked: [DeviceID: Parked] = [:]
  private let now: @Sendable () -> ContinuousClock.Instant

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

  init(
    host: ADBHost, locator: ADBLocator,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.host = host
    self.locator = locator
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
    try await gate.run { () async throws(TransportError) -> DeviceScan in
      let listed: [ADBDevice]
      do throws(ADBError) {
        listed = try await host.devices()
      } catch .cancelled {
        throw .cancelled
      } catch {
        serverUnreachable(error)
        return DeviceScan(devices: [])
      }
      status = .available
      let usable = listed.filter { $0.state == .device }
      let serials = Set(usable.map(\.serial))
      // An address can belong to another device next time: forget what is not listed.
      named = named.filter { serials.contains($0.key) }
      var found: [DeviceID: Found] = [:]
      for device in usable {
        guard let info = await name(device.serial) else { continue }
        var entry = found[info.id] ?? Found(info: info)
        if device.isWireless {
          entry.wireless.append(device.serial)
        } else {
          entry.usb = device.serial
          entry.info = info
        }
        found[info.id] = entry
      }
      routes = found.mapValues { ADBRoutes(usb: $0.usb, wireless: $0.wireless.sorted()) }
      let rescanAfter = settleParked(found: found, listed: Set(listed.map(\.serial)))
      let known = Set(found.keys).union(parked.keys)
      let unauthorized = listed.filter { $0.state == .unauthorized }
        .map(Self.describe)
        .filter { !known.contains($0.id) }
        .sorted { $0.id.serial < $1.id.serial }
      return DeviceScan(
        devices: found.values.map(\.info).filter { parked[$0.id] == nil }.sorted(by: Self.serial),
        notSharing: unauthorized, ejected: parked.values.map(\.info).sorted(by: Self.serial),
        rescanAfter: rescanAfter)
    }
  }

  /// One device as a scan assembles it from its adb serials.
  private struct Found {
    var info: DeviceInfo
    var usb: String?
    var wireless: [String] = []
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    try await gate.run { () async throws(TransportError) -> any DeviceSession in
      if held.contains(id) { throw .deviceBusy }
      guard parked[id] == nil, let routes = routes[id], let serial = routes.preferred,
        let info = named[serial]
      else { throw .deviceNotFound(id) }
      let features: Set<String>
      do throws(ADBError) {
        features = try await host.features(serial)
      } catch .cancelled {
        throw .cancelled
      } catch {
        // Gone since the scan, or the server with it: the next scan says which.
        Self.log.info("not opening \(serial, privacy: .private): \(String(describing: error))")
        throw .deviceNotFound(id)
      }
      held.insert(id)
      return ADBSession(
        host: host, serial: serial, info: info, features: features,
        onRelease: { [weak self] in await self?.release(id) })
    }
  }

  public func park(_ id: DeviceID) async {
    guard held.contains(id), let routes = routes[id], let serial = routes.preferred,
      let info = named[serial]
    else { return }
    parked[id] = Parked(
      info: info, serials: Set(routes.wireless + [routes.usb].compactMap { $0 }))
  }

  public func unpark(_ id: DeviceID) async {
    parked[id] = nil
  }

  private func release(_ id: DeviceID) {
    held.remove(id)
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

  /// The device behind an adb serial, from its properties, read once while it stays listed.
  /// One whose serial cannot be read is left out of this scan and asked again next time.
  private func name(_ serial: String) async -> DeviceInfo? {
    if let info = named[serial] { return info }
    do throws(ADBError) {
      let serialNumber = try await property("ro.serialno", of: serial)
      guard !serialNumber.isEmpty else {
        Self.log.info("\(serial, privacy: .private) reports no ro.serialno; leaving it out")
        return nil
      }
      let manufacturer = try await property("ro.product.manufacturer", of: serial)
      let model = try await property("ro.product.model", of: serial)
      let info = DeviceInfo(
        id: DeviceID(serial: serialNumber),
        manufacturer: manufacturer.isEmpty ? "Unknown" : manufacturer,
        model: model.isEmpty ? "Android device" : model)
      named[serial] = info
      return info
    } catch {
      Self.log.info(
        "reading \(serial, privacy: .private) failed: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private func property(_ name: String, of serial: String) async throws(ADBError) -> String {
    let result = try await host.run(
      serial: serial, command: try ADBShell.command("getprop", [name]))
    guard result.status == 0 else {
      throw .failed("getprop \(name) exited with status \(result.status)")
    }
    return String(bytes: result.stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// Names a device adb lists but will not serve, by its adb serial, as MTP names a device it
  /// cannot read by its USB location.
  private static func describe(_ device: ADBDevice) -> DeviceInfo {
    DeviceInfo(
      id: DeviceID(serial: device.serial), manufacturer: "Unknown",
      model: device.model.map { $0.replacing("_", with: " ") } ?? "Android device")
  }
}
