import DeviceKit
import os

/// Keeping open sessions on the adb connection they opened on (see `ADBHost.pin`).
extension ADBTransport {
  /// Records which connection adb lists each serial on now, drops the tool route of a session
  /// whose connection is gone, and lifts the pins no session holds any more.
  func notePins(_ listed: [ADBDevice]) async {
    transportIDs = Dictionary(
      listed.compactMap { device in device.transportID.map { (device.serial, $0) } },
      uniquingKeysWith: { first, _ in first })
    dropMovedRoutes()
    await liftReleasedPins()
  }

  /// A held device whose route adb no longer lists on the connection it was opened on (it went
  /// away, or another unit answers at the address now) keeps no route for the tools. Its session
  /// is pinned to that connection, so its next operation fails and ends it.
  private func dropMovedRoutes() {
    for (id, entry) in held {
      guard let route = entry.route, let pin = entry.pin, transportIDs[route] != pin.transportID
      else { continue }
      Self.log.info("\(route, privacy: .private) moved to another connection; dropping its route")
      held[id]?.route = nil
    }
  }

  /// Lifts the pins no open session holds. A scan reads names by the connection it listed, so
  /// a pin never hides a new unit from it; from here on that unit may be opened afresh.
  private func liftReleasedPins() async {
    let holding = Set(held.values.compactMap { $0.pin?.serial })
    for (serial, transportID) in pinned where !holding.contains(serial) {
      pinned[serial] = nil
      await host.unpin(serial, from: transportID)
    }
  }
}
