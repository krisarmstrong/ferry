import DeviceKit
import os

/// Which network routes the hub may serve, as `WirelessADB` decides. `ADBTransport` asks it on
/// every scan, so it answers at once from a snapshot. It serves none until `WirelessADB` has
/// loaded its store: the adb server outlives the agent and may already hold a connection that
/// claims a remembered device.
///
/// A route is served when it is an address remembered for the device it answers as (or, for a
/// device paired with a code, adb's own mDNS connection named for it), or when it answers as a
/// device Ferry does not remember (a terminal `adb connect` to a new unit still works; a unit on
/// USB is kept off the network by `CompositeTransport`). An address `WirelessADB` is still
/// deciding about, connecting to or waiting for Allow on, is never served, whoever it claims to
/// be, so a scan cannot race the decision.
public final class WirelessVouching: Sendable {
  private struct State {
    /// False until the store is loaded: until then no network route is served at all.
    var loaded = false
    var vouched: [DeviceID: Set<String>] = [:]
    var paired: Set<DeviceID> = []
    /// Addresses being decided, with how many decisions are under way for each.
    var unsettled: [String: Int] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let changed: AsyncStream<Void>.Continuation

  /// Ticks whenever what may be served changes. adb sends no event for a decision Ferry makes,
  /// so the hub follows this as it follows USB and adb, and scans again. Single consumer; ticks
  /// that arrive faster than they are read coalesce.
  public let changes: AsyncStream<Void>

  public init() {
    (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
  }

  public func serves(_ adbSerial: String, as id: DeviceID) -> Bool {
    state.withLock { state in
      if !state.loaded || state.unsettled[adbSerial] != nil { return false }
      if state.vouched[id]?.contains(adbSerial) == true { return true }
      let mdnsName =
        adbSerial.hasPrefix("adb-\(id.serial)-") && adbSerial.hasSuffix("._adb-tls-connect._tcp")
      if state.paired.contains(id), mdnsName { return true }
      return state.vouched[id] == nil
    }
  }

  func remember(_ entries: [DeviceID: WirelessADB.Entry]) {
    state.withLock { state in
      state.loaded = true
      state.vouched = entries.mapValues { Set($0.addresses.map(\.endpoint.argument)) }
      state.paired = Set(
        entries.filter { $0.value.addresses.contains { $0.learnt == .paired } }.keys)
    }
    changed.yield()
  }

  func unsettle(_ adbSerial: String) {
    state.withLock { $0.unsettled[adbSerial, default: 0] += 1 }
  }

  func settle(_ adbSerial: String) {
    state.withLock { state in
      guard let count = state.unsettled[adbSerial] else { return }
      state.unsettled[adbSerial] = count > 1 ? count - 1 : nil
    }
    changed.yield()
  }
}
