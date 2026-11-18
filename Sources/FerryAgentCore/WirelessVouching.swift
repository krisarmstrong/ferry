import DeviceKit
import os

/// Which network routes the hub may serve, as `WirelessADB` decides. `ADBTransport` asks it on
/// every scan, so it answers at once from a snapshot. It serves none until `WirelessADB` has
/// loaded its store: the adb server outlives the agent and may already hold a connection that
/// claims a remembered device. Nor does it serve any until the domain controller has published
/// its Finder locations: a device with a location counts as known even while it is unplugged.
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
    /// The domain identifiers Ferry has, and the devices of those whose storage it knows; `nil`
    /// until the domain controller first publishes them, and until then nothing is served.
    var locations: (identifiers: Set<String>, devices: Set<DeviceID>)?
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
      guard state.loaded, let locations = state.locations, state.unsettled[adbSerial] == nil
      else { return false }
      if state.vouched[id]?.contains(adbSerial) == true { return true }
      let mdnsName =
        adbSerial.hasPrefix("adb-\(id.serial)-") && adbSerial.hasSuffix("._adb-tls-connect._tcp")
      if state.paired.contains(id), mdnsName { return true }
      // Unknown to Ferry: neither remembered nor with a Finder location, which an unvouched
      // route would otherwise take over while the device is unplugged.
      return state.vouched[id] == nil && !Self.isLocated(id, in: locations)
    }
  }

  /// Whether Ferry has a Finder location for `id`: one whose storage names the device, or, for
  /// one adopted at start and known only by identifier, the identifier of its internal storage
  /// (see `DomainController.location(of:)`).
  private static func isLocated(
    _ id: DeviceID, in locations: (identifiers: Set<String>, devices: Set<DeviceID>)
  ) -> Bool {
    locations.devices.contains(id)
      || DomainController.internalKeys.contains {
        locations.identifiers.contains(
          DomainNaming.identifier(for: StorageID(device: id, key: $0)))
      }
  }

  /// The domain controller's current locations.
  func locate(identifiers: Set<String>, devices: Set<DeviceID>) {
    state.withLock { $0.locations = (identifiers, devices) }
    changed.yield()
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
