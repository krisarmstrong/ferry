import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DomainController")

/// The hub's sessions, as the controller uses them.
extension DomainController {
  /// The domain's item table, for a request that does not touch the device. Waits, and fails,
  /// as `route(_:)` does.
  func items(of domain: String) async throws(TransportError) -> ItemTable {
    try await connected(domain).items
  }

  /// A lease on the device's session. A device the hub no longer serves is disconnected, which
  /// FileProvider retries, whatever the hub says about it.
  func leaseSession(of device: DeviceID) async throws(TransportError) -> SessionLease {
    do throws(TransportError) {
      return try await hub.lease(device)
    } catch {
      throw .deviceDisconnected
    }
  }

  /// Whether the hub holds a session for the device.
  func isServed(_ id: DeviceID) async -> Bool {
    do throws(TransportError) {
      _ = try await hub.session(for: id)
      return true
    } catch {
      log.error(
        "no session for \(id.serial, privacy: .private): \(String(describing: error), privacy: .private)"
      )
      return false
    }
  }
}
