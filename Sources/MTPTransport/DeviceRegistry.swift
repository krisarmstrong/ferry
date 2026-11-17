import DeviceKit
import Dispatch

/// Where a device sits on the USB bus. Unique while the device stays plugged in.
struct BusLocation: Hashable, Sendable {
  let bus: UInt32
  let address: UInt8
}

/// The process-wide record of which devices this process holds open, by bus location.
///
/// A held device is never opened or claimed again: a scan reports it from the record, with no
/// I/O to it. Every other device is opened once per scan, to read its serial, and closed again;
/// the scan remembers where it found each one, so `open(_:)` opens just that location rather
/// than probing the whole bus. Detection blocks on USB, so it runs on this actor's own queue.
/// Scans and opens take turns through `gate`, so two never race for the same interface.
actor DeviceRegistry<Raw: Sendable, Device: Sendable> {
  struct Driver: Sendable {
    var detect: @Sendable () throws(TransportError) -> [Raw]
    var location: @Sendable (Raw) -> BusLocation
    /// Names a device without opening it, for one another process holds.
    var describe: @Sendable (Raw) -> DeviceInfo
    var open: @Sendable (Raw) async throws(TransportError) -> (Device, DeviceInfo)
    var close: @Sendable (Device) async -> Void
  }

  typealias Opened = (device: Device, location: BusLocation)

  private let queue: DispatchSerialQueue
  private let driver: Driver
  private let gate = OperationGate()
  /// Devices handed out by `open(_:)` and not yet released.
  private var held: [BusLocation: DeviceInfo] = [:]
  /// Where the latest scan found each device it could open.
  private var found: [DeviceID: BusLocation] = [:]

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(label: String, driver: Driver) {
    self.queue = DispatchSerialQueue(label: label)
    self.driver = driver
  }

  func scan() async throws(TransportError) -> DeviceScan {
    try await gate.run { () async throws(TransportError) -> DeviceScan in
      var devices: [DeviceInfo] = []
      var busy: [DeviceInfo] = []
      var found: [DeviceID: BusLocation] = [:]
      for raw in try driver.detect() {
        let location = driver.location(raw)
        if let info = held[location] {
          devices.append(info)
          continue
        }
        do throws(TransportError) {
          let (device, info) = try await driver.open(raw)
          await driver.close(device)
          devices.append(info)
          found[info.id] = location
        } catch {
          busy.append(driver.describe(raw))
        }
      }
      self.found = found
      return DeviceScan(devices: devices, busy: busy)
    }
  }

  /// Opens `id` where the latest scan found it and records it held until `release(_:)`.
  func open(_ id: DeviceID) async throws(TransportError) -> Opened {
    try await gate.run { () async throws(TransportError) -> Opened in
      if held.values.contains(where: { $0.id == id }) { throw .deviceBusy }
      guard let location = found[id],
        let raw = try driver.detect().first(where: { driver.location($0) == location })
      else { throw .deviceNotFound(id) }
      let (device, info) = try await driver.open(raw)
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
}
