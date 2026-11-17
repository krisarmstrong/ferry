import DeviceKit

/// In-memory transport that behaves as `MTPTransport` does: a device this process holds is
/// reported by `scan()` without being touched, and opening it again is `.deviceBusy`.
public actor FakeTransport: DeviceTransport {
  private var devices: [FakeDevice]
  private var heldElsewhere: Set<DeviceID> = []
  private var opens: [DeviceID: Int] = [:]
  private var probes: [DeviceID: Int] = [:]
  private var openFailures: [DeviceID: TransportError] = [:]
  public private(set) var scanCount = 0

  public init(devices: [FakeDevice]) {
    self.devices = devices
  }

  // MARK: Test controls

  public func attach(_ device: FakeDevice) {
    devices.append(device)
  }

  /// Unplugs the device: it leaves the scan and every later call on it is `.deviceDisconnected`.
  public func detach(_ id: DeviceID) async {
    guard let index = devices.firstIndex(where: { $0.info.id == id }) else { return }
    await devices.remove(at: index).setDisconnected()
  }

  /// Another app takes or lets go of the device. While it holds it, `scan()` lists it in
  /// `busy` under `busyID(for:)` and `open` is `.deviceBusy`.
  public func setHeldByAnotherApp(_ id: DeviceID, _ held: Bool) {
    if held {
      heldElsewhere.insert(id)
    } else {
      heldElsewhere.remove(id)
    }
  }

  /// How a busy device is identified: its serial is unknown until it can be opened.
  public static func busyID(for id: DeviceID) -> DeviceID {
    DeviceID(serial: "usb-\(id.serial)")
  }

  /// The next `open` of `id` throws `error`.
  public func failNextOpen(of id: DeviceID, with error: TransportError) {
    openFailures[id] = error
  }

  public func openCount(of id: DeviceID) -> Int {
    opens[id, default: 0]
  }

  /// Times `scan()` touched the device to identify it, as `MTPTransport` opens it to read its
  /// serial.
  public func probeCount(of id: DeviceID) -> Int {
    probes[id, default: 0]
  }

  // MARK: DeviceTransport

  public func scan() async throws(TransportError) -> DeviceScan {
    scanCount += 1
    var usable: [DeviceInfo] = []
    var busy: [DeviceInfo] = []
    for device in devices {
      let info = device.info
      if heldElsewhere.contains(info.id) {
        busy.append(
          DeviceInfo(
            id: Self.busyID(for: info.id), manufacturer: info.manufacturer, model: info.model))
      } else {
        if await !device.isOpen { probes[info.id, default: 0] += 1 }
        usable.append(info)
      }
    }
    return DeviceScan(devices: usable, busy: busy)
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    guard let device = devices.first(where: { $0.info.id == id }) else {
      throw .deviceNotFound(id)
    }
    if let failure = openFailures.removeValue(forKey: id) { throw failure }
    if heldElsewhere.contains(id) { throw .deviceBusy }
    if await device.isOpen { throw .deviceBusy }
    opens[id, default: 0] += 1
    await device.markOpen()
    return device
  }
}
