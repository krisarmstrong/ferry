import ADBTransport
import DeviceKit
import Foundation

/// Reconnecting the remembered devices when the agent starts and when adb's server comes back.
extension WirelessADB {
  /// Reconnects the remembered devices adb does not list, a few at a time and outside the gate,
  /// so a user's request never waits behind addresses that do not answer.
  /// A device forgotten after the list was taken is skipped, and is not adopted if it answers.
  func reconnectMissing(_ listed: [ADBDevice]) async {
    var listed = listed
    while true {
      reconnectAgain = false
      await reconnectPass(listed)
      guard reconnectAgain else { break }
      guard let now = try? await adb.devices() else {
        // Gone again: its next list starts the pass.
        reconnectAgain = false
        break
      }
      listed = now
    }
    reconnecting = nil
  }

  private func reconnectPass(_ listed: [ADBDevice]) async {
    let since = forgets
    let offline = Set(listed.filter { $0.state == .offline }.map(\.serial))
    var due = entries.filter { isMissing($0.key, $0.value, from: listed) }.makeIterator()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<Self.reconnectLimit {
        guard let (id, entry) = due.next() else { break }
        group.addTask { await self.reconnect(id, entry, since: since, offline: offline) }
      }
      while await group.next() != nil {
        guard let (id, entry) = due.next() else { continue }
        group.addTask { await self.reconnect(id, entry, since: since, offline: offline) }
      }
    }
  }

  /// An address adb lists offline is disconnected first: `adb connect` would only answer
  /// "already connected" while adb retries it, and that failure would drop the transport. Then a
  /// live device reconnects, and a server cut off from the network finds no route.
  private func reconnect(
    _ id: DeviceID, _ entry: Entry, since: UInt64, offline: Set<String>
  ) async {
    for address in entry.addresses where offline.contains(address.endpoint.argument) {
      try? await adb.disconnect(address.endpoint)
    }
    _ = await reconnect(id, entry, since: since)
  }
}
