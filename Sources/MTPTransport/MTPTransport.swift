import DeviceKit
import Dispatch
import os

/// `DeviceTransport` over libmtp for Android phones and other MTP devices.
///
/// MTP reveals a device's serial only once it is open, so both calls open every attached device
/// and close the ones they do not hand out. A device that cannot be opened is held by another
/// process; when that leaves nothing to report, the call throws `.deviceBusy` so the user hears
/// why rather than seeing an empty list.
public struct MTPTransport: DeviceTransport {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "MTPTransport")
  /// Detection and opening block on USB, so they run here rather than on the cooperative pool;
  /// one queue also keeps concurrent probes from racing each other for the same interface.
  private static let probeQueue = DispatchQueue(label: "io.github.krisarmstrong.ferry.mtp-probe")

  public init() {}

  public func connectedDevices() async throws(TransportError) -> [DeviceInfo] {
    let probe = try await Self.probe()
    for device in probe.opened {
      await device.close()
    }
    if probe.opened.isEmpty, probe.busy { throw .deviceBusy }
    return probe.opened.map(\.info)
  }

  public func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    let probe = try await Self.probe()
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

  private struct Probe: Sendable {
    var opened: [MTPDevice] = []
    /// At least one detected device could not be opened.
    var busy = false
  }

  private static func probe() async throws(TransportError) -> Probe {
    let result: Result<Probe, TransportError> = await withCheckedContinuation { continuation in
      probeQueue.async {
        continuation.resume(returning: Result { () throws(TransportError) in try openAttached() })
      }
    }
    return try result.get()
  }

  private static func openAttached() throws(TransportError) -> Probe {
    var probe = Probe()
    for raw in try MTPDevice.detect() {
      do {
        probe.opened.append(try MTPDevice(opening: raw))
      } catch {
        log.notice("could not open an MTP device: \(String(describing: error), privacy: .public)")
        probe.busy = true
      }
    }
    return probe
  }
}
