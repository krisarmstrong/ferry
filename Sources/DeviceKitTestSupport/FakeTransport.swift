import DeviceKit

/// In-memory transport that behaves as `MTPTransport` does: a device this process holds is
/// reported by `scan()` without being touched, and opening it again is `.deviceBusy`.
public actor FakeTransport: DeviceTransport {
  private var devices: [FakeDevice]
  private var heldElsewhere: Set<DeviceID> = []
  /// Ejected devices. Like `MTPTransport`, which keeps one by its port through the resets its
  /// close causes, the fake reports a parked device as ejected until it is unplugged or
  /// unparked.
  private var parked: Set<DeviceID> = []
  /// Attached without file transfer: seen on USB only, as `MTPTransport` sees a device whose
  /// MTP interface is off.
  private var withoutFileTransfer: [DeviceInfo] = []
  private var opens: [DeviceID: Int] = [:]
  private var probes: [DeviceID: Int] = [:]
  private var openFailures: [DeviceID: TransportError] = [:]
  public private(set) var scanCount = 0
  /// How the transport reaches its devices, as `DeviceScan.method` reports it.
  private let method: ConnectionMethod
  private var methods: [DeviceID: ConnectionMethod] = [:]

  /// `method` is how the transport reaches its devices: the default stands for MTP, a fake for
  /// ADB passes `.usbADB`.
  public init(devices: [FakeDevice], method: ConnectionMethod = .usbFileTransfer) {
    self.devices = devices
    self.method = method
  }

  // MARK: Test controls

  public func attach(_ device: FakeDevice) {
    devices.append(device)
  }

  /// Unplugs the device: it leaves the scan and every later call on it is `.deviceDisconnected`.
  public func detach(_ id: DeviceID) async {
    parked.remove(id)
    withoutFileTransfer.removeAll { $0.id == id }
    guard let index = devices.firstIndex(where: { $0.info.id == id }) else { return }
    await devices.remove(at: index).setDisconnected()
  }

  /// Plugs in a device whose file transfer is off: `scan()` lists it in `notSharing` under
  /// `info`, and it cannot be opened.
  public func attachWithoutFileTransfer(_ info: DeviceInfo) {
    withoutFileTransfer.append(info)
  }

  private var rescanAfter: Duration?

  private var awaiting: [String] = []

  /// A network device at `address` waits for the user to allow this Mac, as adb lists one
  /// `unauthorized` under its `host:port`.
  public func awaitAuthorization(_ address: String) {
    awaiting.append(address)
  }

  /// The transport reaches `id` by `method` from now on, as adb does a device whose cable was
  /// pulled while it stays connected over the network.
  public func setMethod(_ method: ConnectionMethod, for id: DeviceID) {
    methods[id] = method
  }

  /// The next scans ask to be repeated after `delay`, as `MTPTransport` does while an ejected
  /// device's port is empty.
  public func setRescanAfter(_ delay: Duration?) {
    rescanAfter = delay
  }

  /// The transport stops treating `id` as ejected on its own, as `MTPTransport` does once the
  /// device has been gone long enough to count as unplugged, or when the unit turns up on a port
  /// it opens.
  public func forgetEjection(_ id: DeviceID) {
    parked.remove(id)
  }

  public func isParked(_ id: DeviceID) -> Bool {
    parked.contains(id)
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
    let notSharing = withoutFileTransfer
    var ejected: [DeviceInfo] = []
    for device in devices {
      let info = device.info
      if parked.contains(info.id) {
        ejected.append(info)
      } else if heldElsewhere.contains(info.id) {
        busy.append(
          DeviceInfo(
            id: Self.busyID(for: info.id), manufacturer: info.manufacturer, model: info.model))
      } else {
        if await !device.isOpen { probes[info.id, default: 0] += 1 }
        usable.append(info)
      }
    }
    return DeviceScan(
      devices: usable, busy: busy, notSharing: notSharing, ejected: ejected,
      rescanAfter: rescanAfter, method: method, methods: methods, awaitingAuthorization: awaiting)
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    guard let device = devices.first(where: { $0.info.id == id }) else {
      throw .deviceNotFound(id)
    }
    if parked.contains(id) { throw .deviceNotFound(id) }
    if let failure = openFailures.removeValue(forKey: id) { throw failure }
    if heldElsewhere.contains(id) { throw .deviceBusy }
    if await device.isOpen { throw .deviceBusy }
    opens[id, default: 0] += 1
    await device.markOpen()
    await device.setMethod(methods[id] ?? method)
    return device
  }

  public func park(_ id: DeviceID) {
    guard devices.contains(where: { $0.info.id == id }) else { return }
    parked.insert(id)
  }

  public func unpark(_ id: DeviceID) {
    parked.remove(id)
  }
}
