import DeviceKit
import os

/// Keeping the tools off a session whose adb connection has gone.
extension ADBTransport {
  /// Records which connection adb lists each serial on now, and drops the tool route of a
  /// session whose connection is gone.
  func noteTransports(_ listed: [ADBDevice]) {
    transportIDs = Dictionary(
      listed.compactMap { device in device.transportID.map { (device.serial, $0) } },
      uniquingKeysWith: { first, _ in first })
    for (id, entry) in held {
      guard let route = entry.route, let transportID = entry.transportID,
        transportIDs[route] != transportID
      else { continue }
      // The session selects by its own connection, so its next operation fails and ends it.
      Self.log.info("\(route, privacy: .private) moved to another connection; dropping its route")
      held[id]?.route = nil
    }
  }
}
