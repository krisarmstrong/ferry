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
/// the registry or `unpark(_:)` is called. An ejected device is reported as not sharing files,
/// with no I/O, by its port and model: closing it resets an Android device, which enumerates
/// again, so its enumeration does not last. It stays ejected until it is gone from its port for
/// `settleTime` (unplugged) or `unpark(_:)` is called. Every other candidate is opened
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
  /// Devices handed out by `open(_:)` and not yet released, with their ports.
  private var held: [BusLocation: (info: DeviceInfo, port: USBPort)] = [:]
  /// Devices another process holds: opening them failed.
  private var busy: [BusLocation: DeviceInfo] = [:]
  private var ejected: [USBPort: Ejected] = [:]
  /// Each candidate's raw device, or `nil` for one that is not MTP after all, so an enumeration
  /// is resolved (and an unlisted device probed) once.
  private var resolved: [BusLocation: Raw?] = [:]
  /// A device a scan opened and `open(_:)` has not claimed yet.
  private struct Scanned {
    let device: Device
    let info: DeviceInfo
    let port: USBPort
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
      settleEjected(present: Set(attached.map(\.port)))
      resolved = resolved.filter { present.contains($0.key) }
      for (location, gone) in opened where !present.contains(location) {
        opened[location] = nil
        await driver.close(gone.device)
      }
      var devices: [DeviceInfo] = []
      var busyNow: [DeviceInfo] = []
      var notSharing: [DeviceInfo] = []
      for record in attached {
        let location = record.location
        switch driver.candidacy(record) {
        case .ignored:
          continue
        case .notSharing:
          notSharing.append(Self.describe(record))
          continue
        case .mtp:
          break
        }
        // Ejected first: it stays held until its session finishes closing.
        if let info = ejected[record.port]?.info {
          notSharing.append(info)
          continue
        }
        if let info = busy[location] {
          busyNow.append(info)
          continue
        }
        if let info = held[location]?.info ?? opened[location]?.info {
          devices.append(info)
          continue
        }
        guard let raw = resolve(record) else { continue }
        do throws(TransportError) {
          let (device, info) = try await driver.open(raw, location)
          opened[location] = Scanned(device: device, info: info, port: record.port)
          devices.append(info)
        } catch {
          let info = Self.describe(record)
          busyNow.append(info)
          busy[location] = info
        }
      }
      return DeviceScan(devices: devices, busy: busyNow, notSharing: notSharing)
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
  /// gone for `settleTime`: it was unplugged, so plugging it in again mounts it.
  private func settleEjected(present: Set<USBPort>) {
    let now = driver.now()
    for (port, entry) in ejected {
      if present.contains(port) {
        if let since = entry.missingSince, since.duration(to: now) >= Self.settleTime {
          ejected[port] = nil
        } else {
          ejected[port]?.missingSince = nil
        }
      } else if let since = entry.missingSince {
        if since.duration(to: now) >= Self.settleTime { ejected[port] = nil }
      } else {
        ejected[port]?.missingSince = now
      }
    }
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
