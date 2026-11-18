import DeviceKit
import os

/// `DeviceTransport` over MTP and ADB at once, serving each device by the method it prefers.
///
/// Both transports name an Android device by its serial (`ro.serialno` is the USB serial MTP
/// reports), so a device either one lists is one `DeviceID`, listed once, served by its preferred
/// route (see `ConnectionMethod.isPreferred(over:)`): ADB over USB, then MTP, then ADB over the
/// network. A serial alone does not prove a network device is the unit on the cable, so a
/// network route serves a device only while no USB route presents its serial. A
/// device keeps the name MTP gave it once MTP has seen it, so its Finder location is not renamed
/// when the method changes; one only ADB has seen keeps ADB's name.
///
/// A device ADB lists as unauthorised is left to MTP when MTP can serve it, and otherwise listed
/// as not sharing, reached over ADB. A device either transport reports ejected is ejected: MTP
/// can park only a device it holds, so it may still offer one that ADB served when it was
/// ejected. Parking and unparking reach both.
///
/// A device both list as busy or not sharing is listed once, as MTP names it. MTP names such a
/// device by its USB serial when the registry has one, so it merges with ADB's identity; one
/// without falls back to its USB location and cannot be matched.
///
/// A transport whose scan fails is left out of that scan; only when both fail does the scan
/// fail.
public actor CompositeTransport: DeviceTransport {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "CompositeTransport")

  private enum Side {
    case mtp
    case adb
  }

  private let mtp: any DeviceTransport
  private let adb: any DeviceTransport
  /// Which transport serves each usable device, as of the most recent scan.
  private var servers: [DeviceID: Side] = [:]
  /// Each device as MTP last named it.
  private var mtpNames: [DeviceID: DeviceInfo] = [:]
  /// Devices MTP offered as usable in the most recent scan.
  private var overMTP: Set<DeviceID> = []

  public init(mtp: any DeviceTransport, adb: any DeviceTransport) {
    self.mtp = mtp
    self.adb = adb
  }

  public func scan() async throws(TransportError) -> DeviceScan {
    async let mtpScan = Self.attempt(mtp, "MTP")
    async let adbScan = Self.attempt(adb, "ADB")
    let results = await (mtp: mtpScan, adb: adbScan)
    let viaMTP: DeviceScan
    let viaADB: DeviceScan
    switch results {
    case (.failure(let error), .failure):
      throw error
    case (.success(let scan), .failure):
      (viaMTP, viaADB) = (scan, DeviceScan(devices: []))
    case (.failure, .success(let scan)):
      (viaMTP, viaADB) = (DeviceScan(devices: []), scan)
    case (.success(let mtpScan), .success(let adbScan)):
      (viaMTP, viaADB) = (mtpScan, adbScan)
    }
    return merge(mtp: viaMTP, adb: viaADB)
  }

  private func merge(mtp viaMTP: DeviceScan, adb viaADB: DeviceScan) -> DeviceScan {
    for info in viaMTP.devices + viaMTP.ejected {
      mtpNames[info.id] = info
    }
    // A device MTP cannot open is named from its USB descriptors: second best, kept only until
    // MTP opens it.
    for info in viaMTP.busy + viaMTP.notSharing where mtpNames[info.id] == nil {
      mtpNames[info.id] = info
    }
    overMTP = Set(viaMTP.devices.map(\.id))
    var methods: [DeviceID: ConnectionMethod] = [:]
    var ejected: [DeviceInfo] = []
    for (scan, info) in viaMTP.ejected.map({ (viaMTP, $0) }) + viaADB.ejected.map({ (viaADB, $0) })
    where !ejected.contains(where: { $0.id == info.id }) {
      ejected.append(named(info))
      methods[info.id] = scan.method(of: info.id)
    }
    let ejectedIDs = Set(ejected.map(\.id))
    var servers: [DeviceID: Side] = [:]
    var chosen: [DeviceID: DeviceInfo] = [:]
    for (side, scan) in [(Side.adb, viaADB), (.mtp, viaMTP)] {
      for info in scan.devices where !ejectedIDs.contains(info.id) {
        let method = scan.method(of: info.id)
        if let best = methods[info.id], chosen[info.id] != nil, !method.isPreferred(over: best) {
          continue
        }
        servers[info.id] = side
        methods[info.id] = method
        chosen[info.id] = named(info)
      }
    }
    let devices = Array(chosen.values)
    self.servers = servers
    let listed = Set(devices.map(\.id)).union(ejectedIDs)
    var leftOut: [String: [DeviceInfo]] = [:]
    for (list, pick) in [("busy", \DeviceScan.busy), ("notSharing", \DeviceScan.notSharing)] {
      for scan in [viaMTP, viaADB] {
        for info in scan[keyPath: pick] where !listed.contains(info.id) {
          guard methods[info.id] == nil else { continue }
          leftOut[list, default: []].append(info)
          methods[info.id] = scan.method(of: info.id)
        }
      }
    }
    let rescanAfter = [viaMTP.rescanAfter, viaADB.rescanAfter].compactMap { $0 }.min()
    return DeviceScan(
      devices: devices.sorted { $0.id.serial < $1.id.serial }, busy: leftOut["busy"] ?? [],
      notSharing: leftOut["notSharing"] ?? [], ejected: ejected, rescanAfter: rescanAfter,
      method: .usbFileTransfer, methods: methods,
      awaitingAuthorization: viaMTP.awaitingAuthorization + viaADB.awaitingAuthorization)
  }

  private func named(_ info: DeviceInfo) -> DeviceInfo {
    mtpNames[info.id] ?? info
  }

  /// Opens `id` over the transport that serves it. A device ADB serves but whose storages ADB
  /// cannot read yet (locked, or not mounted yet) is opened over MTP instead when MTP offers it,
  /// so a device that works over MTP never shows as not sharing; the hub moves it to ADB once
  /// ADB is ready. If MTP cannot open it either, the ADB session is returned as it is.
  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    switch servers[id] {
    case .mtp: return try await mtp.open(id)
    case nil: throw .deviceNotFound(id)
    case .adb:
      let session = try await adb.open(id)
      guard overMTP.contains(id), await !Self.isReady(session) else { return session }
      do throws(TransportError) {
        let fallback = try await mtp.open(id)
        await session.close()
        return fallback
      } catch {
        return session
      }
    }
  }

  private static func isReady(_ session: any DeviceSession) async -> Bool {
    do throws(TransportError) {
      return try await !session.storages().isEmpty
    } catch {
      return false
    }
  }

  public func park(_ id: DeviceID) async {
    await mtp.park(id)
    await adb.park(id)
  }

  public func unpark(_ id: DeviceID) async {
    await mtp.unpark(id)
    await adb.unpark(id)
  }

  private static func attempt(_ transport: any DeviceTransport, _ name: String) async
    -> Result<DeviceScan, TransportError>
  {
    do throws(TransportError) {
      return .success(try await transport.scan())
    } catch {
      log.error(
        "scanning over \(name, privacy: .public) failed: \(String(describing: error), privacy: .private)"
      )
      return .failure(error)
    }
  }
}
