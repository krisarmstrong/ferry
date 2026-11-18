import DeviceKit
import Dispatch

/// Where a device sits on the USB bus, and which enumeration of it this is. A replug or a USB
/// mode switch can reuse the port and the address, but never the IOKit registry entry, so a
/// location stands for one enumeration of one device.
struct BusLocation: Hashable, Sendable {
  let bus: UInt32
  let address: UInt8
  let registryID: UInt64
}

/// The process-wide record of which devices this process holds open, and which it leaves alone.
///
/// A scan reads the IOKit registry, which costs no USB I/O, and touches only candidates: a device
/// that may speak MTP (see `USBCandidates`). With no candidate attached, libmtp is never called.
/// A held device is never opened or claimed again: a scan reports it from the record. A busy
/// device (one another app holds) is reported from the record too, with no I/O, until it leaves
/// the registry or `unpark(_:)` is called. An ejected device is reported in `DeviceScan.ejected`,
/// with no I/O, by its port: closing it resets an Android device, which enumerates again (and
/// may come back with another product ID), so its enumeration does not last. It stays ejected,
/// and reported, until its port has been empty for `settleTime` (unplugged) or `unpark(_:)` is
/// called. While its port is empty the scan says when to scan again, so the unplug is noticed
/// without another USB event. The port goes empty when the device's departure is reported, and
/// the watcher ticks on that departure, so the time runs from the USB event, not from whenever
/// the next scan happens. Every other candidate is opened
/// by the scan, to read its serial, and kept open: `open(_:)` hands that handle over rather than
/// opening again, because libmtp's release resets an Android device, which then enumerates anew
/// at another registry entry. A kept handle whose device left is closed by the next scan. Scans
/// and opens take turns through `gate`, so two never race for the same interface; libmtp blocks
/// on USB, so this actor runs on its own queue.
actor DeviceRegistry<Raw: Sendable, Device: Sendable> {
  struct Driver: Sendable {
    /// The USB devices attached now, from the IOKit registry.
    var attached: @Sendable () throws(TransportError) -> [USBDeviceRecord]
    var candidacy: @Sendable (USBDeviceRecord) -> USBCandidacy
    /// libmtp's raw device for an MTP candidate, or `nil` if it turns out not to be one.
    var resolve: @Sendable (USBDeviceRecord) -> Raw?
    var open: @Sendable (Raw, BusLocation) async throws(TransportError) -> (Device, DeviceInfo)
    var close: @Sendable (Device) async -> Void
    var now: @Sendable () -> ContinuousClock.Instant
  }

  /// How long an ejected device must be gone from its port to count as unplugged. A reset
  /// re-enumerates in milliseconds; a person unplugging and replugging takes longer.
  static var settleTime: Duration { .seconds(3) }

  private struct Ejected {
    let info: DeviceInfo
    /// When a scan first found the port empty, if it has been since the device was last seen.
    var missingSince: ContinuousClock.Instant?
  }

  typealias Opened = (device: Device, location: BusLocation)

  private let queue: DispatchSerialQueue
  private let driver: Driver
  private let gate = OperationGate()
  /// Devices handed out by `open(_:)` and not yet released, with their ports' location IDs.
  private var held: [BusLocation: (info: DeviceInfo, port: UInt32)] = [:]
  /// Devices another process holds: opening them failed.
  private var busy: [BusLocation: DeviceInfo] = [:]
  /// Ejected devices by the location ID of their port.
  private var ejected: [UInt32: Ejected] = [:]
  /// Each candidate's raw device, or `nil` for one that is not MTP after all, so an enumeration
  /// is resolved (and an unlisted device probed) once.
  private var resolved: [BusLocation: Raw?] = [:]
  /// A device a scan opened and `open(_:)` has not claimed yet.
  private struct Scanned {
    let device: Device
    let info: DeviceInfo
    let port: UInt32
  }

  private var opened: [BusLocation: Scanned] = [:]

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(label: String, driver: Driver) {
    self.queue = DispatchSerialQueue(label: label)
    self.driver = driver
  }

  func scan() async throws(TransportError) -> DeviceScan {
    try await gate.run { () async throws(TransportError) -> DeviceScan in
      let attached = try driver.attached()
      let present = Set(attached.map(\.location))
      busy = busy.filter { present.contains($0.key) }
      let rescanAfter = settleEjected(present: Set(attached.map(\.locationID)))
      resolved = resolved.filter { present.contains($0.key) }
      for (location, gone) in opened where !present.contains(location) {
        opened[location] = nil
        await driver.close(gone.device)
      }
      let occupied = Set(attached.map(\.locationID))
      var found = Found(ejected: ejected.filter { !occupied.contains($0.key) }.map(\.value.info))
      for record in attached {
        await report(record, into: &found)
      }
      return DeviceScan(
        devices: found.devices, busy: found.busy, notSharing: found.notSharing,
        ejected: found.ejected, rescanAfter: rescanAfter)
    }
  }

  /// What a scan found, list by list.
  private struct Found {
    var devices: [DeviceInfo] = []
    var busy: [DeviceInfo] = []
    var notSharing: [DeviceInfo] = []
    var ejected: [DeviceInfo]
  }

  /// Sorts one attached device into `found`, opening it only if it is a new candidate.
  private func report(_ record: USBDeviceRecord, into found: inout Found) async {
    let location = record.location
    // Ejected first, before any I/O: it stays held until its session finishes closing, and any
    // enumeration on its port is it, whatever product ID it comes back with.
    if let info = ejected[record.locationID]?.info {
      found.ejected.append(info)
      return
    }
    switch driver.candidacy(record) {
    case .ignored:
      return
    case .notSharing:
      found.notSharing.append(Self.describe(record))
      return
    case .mtp:
      break
    }
    if let info = busy[location] {
      found.busy.append(info)
      return
    }
    if let info = held[location]?.info ?? opened[location]?.info {
      found.devices.append(info)
      return
    }
    guard let raw = resolve(record) else { return }
    do throws(TransportError) {
      let (device, info) = try await driver.open(raw, location)
      if ejected.values.contains(where: { $0.info.id == info.id }) {
        // The ejected device on another port: let it go again.
        await driver.close(device)
        return
      }
      opened[location] = Scanned(device: device, info: info, port: record.locationID)
      found.devices.append(info)
    } catch {
      let info = Self.describe(record)
      found.busy.append(info)
      busy[location] = info
    }
  }

  /// Hands over the device `id` a scan opened, and records it held until `release(_:)`.
  func open(_ id: DeviceID) async throws(TransportError) -> Opened {
    try await gate.run { () async throws(TransportError) -> Opened in
      let leftAlone =
        ejected.values.contains { $0.info.id == id } || busy.values.contains { $0.id == id }
      if leftAlone { throw .deviceNotFound(id) }
      if held.values.contains(where: { $0.info.id == id }) { throw .deviceBusy }
      guard let (location, scanned) = opened.first(where: { $0.value.info.id == id }) else {
        throw .deviceNotFound(id)
      }
      opened[location] = nil
      guard try driver.attached().contains(where: { $0.location == location }) else {
        await driver.close(scanned.device)
        throw .deviceNotFound(id)
      }
      held[location] = (scanned.info, scanned.port)
      return (scanned.device, location)
    }
  }

  /// Called once the device at `location` is closed or gone.
  func release(_ location: BusLocation) {
    held[location] = nil
  }

  /// Leaves the held device `id` alone once it is released, on whatever enumeration it comes
  /// back as, until it is unplugged or `unpark(_:)` is called.
  func park(_ id: DeviceID) {
    guard let device = held.values.first(where: { $0.info.id == id }) else { return }
    ejected[device.port] = Ejected(info: device.info, missingSince: nil)
  }

  /// Lets the next scan open `id` again: a device that was busy or ejected.
  func unpark(_ id: DeviceID) {
    busy = busy.filter { $0.value.id != id }
    ejected = ejected.filter { $0.value.info.id != id }
  }

  /// Notes when an ejected device's port went empty, and forgets an ejected device that has been
  /// gone for `settleTime`: it was unplugged, so plugging it in again mounts it. Returns how
  /// long until the soonest empty port settles, if any is still settling.
  private func settleEjected(present: Set<UInt32>) -> Duration? {
    let now = driver.now()
    var soonest: Duration?
    for (port, entry) in ejected {
      if present.contains(port), entry.missingSince == nil { continue }
      guard let since = entry.missingSince else {
        ejected[port]?.missingSince = now
        soonest = min(soonest ?? Self.settleTime, Self.settleTime)
        continue
      }
      let gone = since.duration(to: now)
      if gone >= Self.settleTime {
        ejected[port] = nil
      } else if present.contains(port) {
        ejected[port]?.missingSince = nil
      } else {
        soonest = min(soonest ?? Self.settleTime - gone, Self.settleTime - gone)
      }
    }
    return soonest
  }

  private func resolve(_ record: USBDeviceRecord) -> Raw? {
    if let known = resolved[record.location] { return known }
    let raw = driver.resolve(record)
    resolved[record.location] = raw
    return raw
  }

  /// Names a device from its registry properties, for one Ferry cannot open. Its serial is
  /// unknown, so it is identified by where it is, which is unique while it stays plugged in.
  static func describe(_ record: USBDeviceRecord) -> DeviceInfo {
    let location = record.location
    return DeviceInfo(
      id: DeviceID(serial: "usb-\(location.bus)-\(location.address)"),
      manufacturer: record.vendorName ?? "Unknown", model: record.productName ?? "USB device")
  }
}
