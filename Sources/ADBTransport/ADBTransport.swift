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
  /// Devices left alone after an eject, until no route to them is listed or `unpark(_:)`.
  private var parked: Set<DeviceID> = []

  public init(port: UInt16 = 5037, locator: ADBLocator = ADBLocator()) {
    self.init(host: ADBHost(port: port, locator: locator), locator: locator)
  }

  init(host: ADBHost, locator: ADBLocator) {
    self.host = host
    self.locator = locator
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
      // Gone from the list means unplugged (or disconnected): it mounts when it returns.
      parked.formIntersection(found.keys)
      let infos = found.values.map(\.info).sorted { $0.id.serial < $1.id.serial }
      let listedIDs = Set(found.keys)
      let unauthorized = listed.filter { $0.state == .unauthorized }
        .map(Self.describe)
        .filter { !listedIDs.contains($0.id) }
        .sorted { $0.id.serial < $1.id.serial }
      return DeviceScan(
        devices: infos.filter { !parked.contains($0.id) }, notSharing: unauthorized,
        ejected: infos.filter { parked.contains($0.id) })
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
      guard !parked.contains(id), let routes = routes[id], let serial = routes.preferred,
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
    guard held.contains(id) else { return }
    parked.insert(id)
  }

  public func unpark(_ id: DeviceID) async {
    parked.remove(id)
  }

  private func release(_ id: DeviceID) {
    held.remove(id)
  }

  /// Records why the server could not be used. Its devices may come back under other
  /// addresses, so what was learnt of them is dropped; parked devices stay parked.
  private func serverUnreachable(_ error: ADBError) {
    named = [:]
    routes = [:]
    if error == .serverUnavailable {
      status = locator.adbURL() == nil ? .notInstalled : .serverDown
    } else {
      status = .serverDown
      Self.log.error("listing adb devices failed: \(String(describing: error), privacy: .public)")
    }
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
