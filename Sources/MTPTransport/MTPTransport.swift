import DeviceKit

/// `DeviceTransport` over libmtp for Android phones and other MTP devices.
///
/// MTP reveals a device's serial only once it is open, so both calls open every attached device
/// and close the ones they do not hand out. A device that cannot be opened is held by another
/// process; when that leaves nothing to report, the call throws `.deviceBusy` so the user hears
/// why rather than seeing an empty list.
public struct MTPTransport: DeviceTransport {
  private static let prober = DeviceProber<RawDeviceRef, MTPDevice>(
    label: "io.github.krisarmstrong.ferry.mtp-probe", detect: MTPDevice.detect,
    open: MTPDevice.open)

  public init() {}

  public func connectedDevices() async throws(TransportError) -> [DeviceInfo] {
    let probe = try await Self.prober.probe()
    for device in probe.opened {
      await device.close()
    }
    if probe.opened.isEmpty, probe.busy { throw .deviceBusy }
    return probe.opened.map(\.info)
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    let probe = try await Self.prober.probe()
    var match: MTPDevice?
    for device in probe.opened {
      if match == nil, device.info.id == id {
        match = device
      } else {
        await device.close()
      }
    }
    guard let match else { throw probe.busy ? .deviceBusy : .deviceNotFound(id) }
    return MTPSession(device: match)
  }
}
