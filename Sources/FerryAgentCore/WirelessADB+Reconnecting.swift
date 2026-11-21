import ADBTransport
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
    var due = entries.filter { isMissing($0.key, $0.value, from: listed) }.makeIterator()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<Self.reconnectLimit {
        guard let (id, entry) = due.next() else { break }
        group.addTask { _ = await self.reconnect(id, entry, since: since) }
      }
      while await group.next() != nil {
        guard let (id, entry) = due.next() else { continue }
        group.addTask { _ = await self.reconnect(id, entry, since: since) }
      }
    }
  }
}
