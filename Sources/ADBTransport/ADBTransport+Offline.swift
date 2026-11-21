import DeviceKit
import Foundation

/// A server whose first read from a USB device failed as it started ("connection terminated:
/// read failed") lists the device offline until it is replugged.
extension ADBTransport {
  /// How long a USB device may stay offline before Ferry asks adb to reconnect it, and how long
  /// after that before it asks for a replug: longer than a starting server lists one offline.
  static let offlineGrace = Duration.seconds(10)

  struct Offline {
    let since: ContinuousClock.Instant
    var reconnected: ContinuousClock.Instant?
  }

  /// A USB device offline for `offlineGrace`, and not ejected, is reconnected (`host:reconnect-offline`), once
  /// per stretch offline; one still offline `offlineGrace` after that needs a replug. Returns
  /// those, and when to scan again for the next step, since nothing else may tick meanwhile.
  func noteOffline(_ listed: [ADBDevice]) async -> (Set<DeviceID>, Duration?) {
    let now = now()
    // An ejected device is left alone, offline or not.
    let parkedSerials = Set(parked.values.flatMap(\.serials))
    let serials = listed.filter {
      $0.state == .offline && !$0.isWireless && !parkedSerials.contains($0.serial)
    }
    offline = offline.filter { entry in serials.contains { $0.serial == entry.key } }
    var stuck: Set<DeviceID> = []
    var soonest: Duration?
    var reconnect = false
    for device in serials {
      var entry = offline[device.serial] ?? Offline(since: now)
      let waited = (entry.reconnected ?? entry.since).duration(to: now)
      if waited < Self.offlineGrace {
        soonest = min(soonest ?? Self.offlineGrace, Self.offlineGrace - waited)
      } else if entry.reconnected == nil {
        entry.reconnected = now
        reconnect = true
        soonest = min(soonest ?? Self.offlineGrace, Self.offlineGrace)
      } else {
        stuck.insert(Self.describe(device).id)
      }
      offline[device.serial] = entry
    }
    if reconnect {
      Self.log.notice("a USB device stayed offline; asking adb to reconnect it")
      do throws(ADBError) {
        try await Self.within(answerLimit, on: clock) { [host] () async throws(ADBError) in
          try await host.reconnectOffline()
        }
      } catch {
        Self.log.error(
          "reconnecting offline devices failed: \(String(describing: error), privacy: .private)")
      }
    }
    return (stuck, soonest)
  }
}
