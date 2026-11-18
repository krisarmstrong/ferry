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
/// A held device is never opened or claimed again: a scan reports it from the record. A parked
/// device (one another app holds, or one the user ejected) is reported from the record too, with
/// no I/O, until it leaves the registry or `unpark(_:)` is called. Every other candidate is opened
/// once per scan, to read its serial, and closed again; the scan remembers where it found each
/// one, so `open(_:)` opens just that enumeration. Scans and opens take turns through `gate`, so
/// two never race for the same interface; libmtp blocks on USB, so this actor runs on its own
/// queue.
actor DeviceRegistry<Raw: Sendable, Device: Sendable> {
  struct Driver: Sendable {
    /// The USB devices attached now, from the IOKit registry.
    var attached: @Sendable () throws(TransportError) -> [USBDeviceRecord]
    var candidacy: @Sendable (USBDeviceRecord) -> USBCandidacy
    /// libmtp's raw device for an MTP candidate, or `nil` if it turns out not to be one.
    var resolve: @Sendable (USBDeviceRecord) -> Raw?
    var open: @Sendable (Raw, BusLocation) async throws(TransportError) -> (Device, DeviceInfo)
    var close: @Sendable (Device) async -> Void
  }

  typealias Opened = (device: Device, location: BusLocation)

  private enum Parked {
    /// Another process holds it: opening it failed.
    case busy(DeviceInfo)
    /// The user ejected it: it stays listed as not sharing files.
    case ejected(DeviceInfo)

    var info: DeviceInfo {
      switch self {
      case .busy(let info), .ejected(let info): info
      }
    }
  }

  private let queue: DispatchSerialQueue
  private let driver: Driver
  private let gate = OperationGate()
  /// Devices handed out by `open(_:)` and not yet released.
  private var held: [BusLocation: DeviceInfo] = [:]
  private var parked: [BusLocation: Parked] = [:]
  /// Each candidate's raw device, or `nil` for one that is not MTP after all, so an enumeration
  /// is resolved (and an unlisted device probed) once.
  private var resolved: [BusLocation: Raw?] = [:]
  /// Where the latest scan found each device it could open.
  private var found: [DeviceID: (location: BusLocation, raw: Raw)] = [:]

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
      parked = parked.filter { present.contains($0.key) }
      resolved = resolved.filter { present.contains($0.key) }
      var devices: [DeviceInfo] = []
      var busy: [DeviceInfo] = []
      var notSharing: [DeviceInfo] = []
      var found: [DeviceID: (location: BusLocation, raw: Raw)] = [:]
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
        // Parked first: an ejected device stays held until its session finishes closing.
        switch parked[location] {
        case .busy(let info):
          busy.append(info)
          continue
        case .ejected(let info):
          notSharing.append(info)
          continue
        case nil:
          break
        }
        if let info = held[location] {
          devices.append(info)
          continue
        }
        guard let raw = resolve(record) else { continue }
        do throws(TransportError) {
          let (device, info) = try await driver.open(raw, location)
          await driver.close(device)
          devices.append(info)
          found[info.id] = (location, raw)
        } catch {
          let info = Self.describe(record)
          busy.append(info)
          parked[location] = .busy(info)
        }
      }
      self.found = found
      return DeviceScan(devices: devices, busy: busy, notSharing: notSharing)
    }
  }

  /// Opens `id` where the latest scan found it and records it held until `release(_:)`.
  func open(_ id: DeviceID) async throws(TransportError) -> Opened {
    try await gate.run { () async throws(TransportError) -> Opened in
      if parked.values.contains(where: { $0.info.id == id }) { throw .deviceNotFound(id) }
      if held.values.contains(where: { $0.id == id }) { throw .deviceBusy }
      guard let (location, raw) = found[id],
        try driver.attached().contains(where: { $0.location == location })
      else { throw .deviceNotFound(id) }
      let (device, info) = try await driver.open(raw, location)
      guard info.id == id else {
        await driver.close(device)
        throw .deviceNotFound(id)
      }
      held[location] = info
      return (device, location)
    }
  }

  /// Called once the device at `location` is closed or gone.
  func release(_ location: BusLocation) {
    held[location] = nil
  }

  /// Leaves the held device `id` alone once it is released, until it is unplugged or
  /// `unpark(_:)` is called.
  func park(_ id: DeviceID) {
    guard let (location, info) = held.first(where: { $0.value.id == id }) else { return }
    parked[location] = .ejected(info)
  }

  /// Lets the next scan open `id` again: a device that was busy or ejected.
  func unpark(_ id: DeviceID) {
    parked = parked.filter { $0.value.info.id != id }
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
