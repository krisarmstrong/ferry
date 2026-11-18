/// What a transport found on the bus.
public struct DeviceScan: Sendable, Equatable, Codable {
  /// Devices this process can use, including those it already holds open.
  public let devices: [DeviceInfo]
  /// Devices another process holds. Their serial is unknown, so each is identified by its USB
  /// location (`usb-<bus>-<address>`), which is unique only while it stays plugged in.
  public let busy: [DeviceInfo]
  /// Devices attached but not sharing files: an Android device with file transfer off, named
  /// from USB alone like `busy`.
  public let notSharing: [DeviceInfo]
  /// Devices this process ejected, under their own identity. One is listed while it is attached
  /// and for a short while after it leaves, until that counts as an unplug: closing an Android
  /// device resets it, so it leaves and comes back on its own.
  public let ejected: [DeviceInfo]
  /// When to scan again without waiting for a USB event, so an ejected device that left is
  /// noticed once its absence counts as an unplug. `nil` when nothing is waiting.
  public let rescanAfter: Duration?
  /// How the transport reaches every device it lists, unless `methods` says otherwise.
  public let method: ConnectionMethod
  /// Devices the transport reaches another way than `method`.
  public let methods: [DeviceID: ConnectionMethod]
  /// Network devices (`host:port`) waiting for the user to allow this Mac on them. They name no
  /// unit until they are allowed, so they are not devices yet.
  public let awaitingAuthorization: [String]
  /// Devices a USB route presents in any state, usable or not (unauthorised, offline). A
  /// network route never serves one of these: a serial alone does not prove a network device is
  /// the unit on the cable.
  public let presentOverUSB: Set<DeviceID>

  /// `method` is how the transport reaches what it lists: MTP is always `.usbFileTransfer`. A
  /// transport with more than one route names the exceptions in `methods`.
  public init(
    devices: [DeviceInfo], busy: [DeviceInfo] = [], notSharing: [DeviceInfo] = [],
    ejected: [DeviceInfo] = [], rescanAfter: Duration? = nil,
    method: ConnectionMethod = .usbFileTransfer, methods: [DeviceID: ConnectionMethod] = [:],
    awaitingAuthorization: [String] = [], presentOverUSB: Set<DeviceID> = []
  ) {
    self.devices = devices
    self.busy = busy
    self.notSharing = notSharing
    self.ejected = ejected
    self.rescanAfter = rescanAfter
    self.method = method
    self.methods = methods.filter { $0.value != method }
    self.awaitingAuthorization = awaitingAuthorization
    self.presentOverUSB = presentOverUSB
  }

  /// How the transport reaches `id`.
  public func method(of id: DeviceID) -> ConnectionMethod {
    methods[id] ?? method
  }
}
