import DeviceKit

public actor FakeTransport: DeviceTransport {
  private var devices: [FakeDevice]
  private let exclusive: Bool
  private var opens: [DeviceID: Int] = [:]
  private var openFailures: [DeviceID: TransportError] = [:]

  /// With `exclusive`, the transport behaves as `MTPTransport` does: a device with an open
  /// session is left out of `connectedDevices()`, and a second `open` of it is `.deviceBusy`.
  public init(devices: [FakeDevice], exclusive: Bool = false) {
    self.devices = devices
    self.exclusive = exclusive
  }

  // MARK: Test controls

  public func attach(_ device: FakeDevice) {
    devices.append(device)
  }

  /// Unplugs the device: it leaves the list and every later call on it is `.deviceDisconnected`.
  public func detach(_ id: DeviceID) async {
    guard let index = devices.firstIndex(where: { $0.info.id == id }) else { return }
    await devices.remove(at: index).setDisconnected()
  }

  /// The next `open` of `id` throws `error`.
  public func failNextOpen(of id: DeviceID, with error: TransportError) {
    openFailures[id] = error
  }

  public func openCount(of id: DeviceID) -> Int {
    opens[id, default: 0]
  }

  // MARK: DeviceTransport

  public func connectedDevices() async throws(TransportError) -> [DeviceInfo] {
    guard exclusive else { return devices.map(\.info) }
    var free: [DeviceInfo] = []
    for device in devices where await !device.isOpen {
      free.append(device.info)
    }
    if free.isEmpty, !devices.isEmpty { throw .deviceBusy }
    return free
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    guard let device = devices.first(where: { $0.info.id == id }) else {
      throw .deviceNotFound(id)
    }
    if let failure = openFailures.removeValue(forKey: id) { throw failure }
    if exclusive, await device.isOpen { throw .deviceBusy }
    opens[id, default: 0] += 1
    await device.markOpen()
    return device
  }
}
