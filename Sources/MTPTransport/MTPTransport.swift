import DeviceKit

/// `DeviceTransport` over libmtp for Android phones and other MTP devices.
///
/// MTP reveals a device's serial only once it is open, so a scan opens each device this process
/// does not hold and closes it again. One `DeviceRegistry` serves the whole process, so a device
/// held by any session is reported without being touched and is never opened twice. A device
/// that cannot be opened is held by another process and is reported in `DeviceScan.busy`.
public struct MTPTransport: DeviceTransport {
  private static let registry = DeviceRegistry<RawDeviceRef, MTPDevice>(
    label: "io.github.krisarmstrong.ferry.mtp-registry",
    driver: .init(
      detect: MTPDevice.detect,
      location: { BusLocation(bus: $0.raw.bus_location, address: $0.raw.devnum) },
      describe: MTPDevice.describe,
      open: { raw throws(TransportError) in
        let device = try await MTPDevice.open(raw)
        return (device, device.info)
      },
      close: { await $0.close() }))

  public init() {}

  public func scan() async throws(TransportError) -> DeviceScan {
    try await Self.registry.scan()
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    let (device, location) = try await Self.registry.open(id)
    return MTPSession(device: device) { await Self.registry.release(location) }
  }
}
