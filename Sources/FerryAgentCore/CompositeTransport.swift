import DeviceKit
import os

/// `DeviceTransport` over MTP and ADB at once, serving each device by the method it prefers.
///
/// Both transports name an Android device by its serial (`ro.serialno` is the USB serial MTP
/// reports), so a device either one lists is one `DeviceID`, listed once. ADB wins wherever it
/// can serve the device (see `ConnectionMethod.isPreferred(over:)`); MTP serves the rest. A
/// device keeps the name MTP gave it once MTP has seen it, so its Finder location is not renamed
/// when the method changes; one only ADB has seen keeps ADB's name.
///
/// A device ADB lists as unauthorised is left to MTP when MTP can serve it, and otherwise listed
/// as not sharing, reached over ADB. A device either transport reports ejected is ejected: MTP
/// can park only a device it holds, so it may still offer one that ADB served when it was
/// ejected. Parking and unparking reach both.
///
/// MTP's `busy` and `notSharing` devices are named by USB location and ADB's unauthorised network
/// devices by `host:port`: neither matches a serial, so such a device can be listed once by each.
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
    var methods: [DeviceID: ConnectionMethod] = [:]
    var ejected: [DeviceInfo] = []
    for (scan, info) in viaMTP.ejected.map({ (viaMTP, $0) }) + viaADB.ejected.map({ (viaADB, $0) })
    where !ejected.contains(where: { $0.id == info.id }) {
      ejected.append(named(info))
      methods[info.id] = scan.method(of: info.id)
    }
    let ejectedIDs = Set(ejected.map(\.id))
    var servers: [DeviceID: Side] = [:]
    var devices: [DeviceInfo] = []
    for (side, scan) in [(Side.adb, viaADB), (.mtp, viaMTP)] {
      for info in scan.devices where servers[info.id] == nil && !ejectedIDs.contains(info.id) {
        servers[info.id] = side
        methods[info.id] = scan.method(of: info.id)
        devices.append(named(info))
      }
    }
    self.servers = servers
    let listed = Set(devices.map(\.id)).union(ejectedIDs)
    var leftOut: [String: [DeviceInfo]] = [:]
    for (list, pick) in [("busy", \DeviceScan.busy), ("notSharing", \DeviceScan.notSharing)] {
      for scan in [viaMTP, viaADB] {
        for info in scan[keyPath: pick] where !listed.contains(info.id) {
          leftOut[list, default: []].append(info)
          methods[info.id] = methods[info.id] ?? scan.method(of: info.id)
        }
      }
    }
    let rescanAfter = [viaMTP.rescanAfter, viaADB.rescanAfter].compactMap { $0 }.min()
    return DeviceScan(
      devices: devices.sorted { $0.id.serial < $1.id.serial }, busy: leftOut["busy"] ?? [],
      notSharing: leftOut["notSharing"] ?? [], ejected: ejected, rescanAfter: rescanAfter,
      method: .usbFileTransfer, methods: methods)
  }

  private func named(_ info: DeviceInfo) -> DeviceInfo {
    mtpNames[info.id] ?? info
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    switch servers[id] {
    case .adb: try await adb.open(id)
    case .mtp: try await mtp.open(id)
    case nil: throw .deviceNotFound(id)
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
