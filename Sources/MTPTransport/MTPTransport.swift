import DeviceKit

/// `DeviceTransport` over libmtp for Android phones and other MTP devices.
///
/// Candidates come from the IOKit registry, never from probing the bus, so an iPhone, a camera or
/// any device that is not MTP is never opened. MTP reveals a device's serial only once it is
/// open, so a scan opens each candidate this process does not hold and keeps the handle for
/// `open(_:)`: closing it would reset an Android device, which then enumerates anew. One
/// `DeviceRegistry` serves the whole process, so a device held by any session is reported without
/// being touched and is never opened twice. A device that cannot be opened is held by another
/// process and is reported in `DeviceScan.busy`.
public struct MTPTransport: DeviceTransport {
  private static let registry = DeviceRegistry<RawDeviceRef, MTPDevice>(
    label: "io.github.krisarmstrong.ferry.mtp-registry",
    driver: .init(
      attached: USBRegistry.attached,
      candidacy: MTPTransport.candidacy(of:),
      resolve: MTPDeviceTable.rawDevice(for:),
      open: { raw, location throws(TransportError) in
        let device = try await MTPDevice.open(raw, registryID: location.registryID)
        return (device, device.info)
      },
      close: { await $0.close() },
      now: { ContinuousClock.now }))

  static func candidacy(of device: USBDeviceRecord) -> USBCandidacy {
    USBCandidates.candidacy(
      of: device,
      inTable: MTPDeviceTable.contains(vendor: device.vendorID, product: device.productID))
  }

  public init() {}

  public func scan() async throws(TransportError) -> DeviceScan {
    try await Self.registry.scan()
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    let (device, location) = try await Self.registry.open(id)
    return MTPSession(device: device) { await Self.registry.release(location) }
  }

  public func park(_ id: DeviceID) async {
    await Self.registry.park(id)
  }

  public func unpark(_ id: DeviceID) async {
    await Self.registry.unpark(id)
  }
}
