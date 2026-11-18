import DeviceKit
import os

/// Which network routes the hub may serve, as `WirelessADB` decides. `ADBTransport` asks it on
/// every scan, so it answers at once from a snapshot.
///
/// Nothing on the network is served until `WirelessADB` has loaded its store and the domain
/// controller has published its Finder locations: the adb server outlives the agent and may
/// already hold a connection that claims a known device. Then a route is served when:
/// - it is an address remembered for the device it answers as, or, for a device paired with a
///   code, adb's own mDNS connection named for it; or
/// - the device it answers as is neither remembered nor has a Finder location, and the location
///   set is complete. A terminal `adb connect` to a new unit works, but only until Ferry has made
///   a location for it: after that the same route is refused (from the next time it is opened,
///   such as after a restart), and the address is offered in the menu for the user to confirm,
///   which makes it remembered.
///
/// While the location set is incomplete (the system's domains could not be listed), only
/// remembered routes are served. An address `WirelessADB` is still deciding about, connecting to
/// or waiting for Allow on, is never served, whoever it claims to be, so a scan cannot race the
/// decision. A unit on USB is kept off the network by `CompositeTransport`.
public final class WirelessVouching: Sendable {
  struct Locations {
    let identifiers: Set<String>
    let devices: Set<DeviceID>
    /// False when the system's domains could not be listed: some locations may be missing.
    let complete: Bool
  }

  private struct State {
    /// False until the store is loaded: until then no network route is served at all.
    var loaded = false
    /// `nil` until the domain controller first publishes them, and until then nothing is served.
    var locations: Locations?
    var vouched: [DeviceID: Set<String>] = [:]
    var paired: Set<DeviceID> = []
    /// Addresses being decided, with how many decisions are under way for each.
    var unsettled: [String: Int] = [:]
    /// Routes already reported as refused for a located device.
    var reported: Set<String> = []
  }

  /// A route refused because the device it claims has a Finder location.
  struct Refusal: Sendable {
    let adbSerial: String
    let id: DeviceID
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let changed: AsyncStream<Void>.Continuation

  /// Ticks whenever what may be served changes. adb sends no event for a decision Ferry makes,
  /// so the hub follows this as it follows USB and adb, and scans again. Single consumer; ticks
  /// that arrive faster than they are read coalesce.
  public let changes: AsyncStream<Void>
  /// Each route refused because its device has a Finder location, once, for `WirelessADB` to
  /// offer in the menu. Single consumer.
  let refusals: AsyncStream<Refusal>
  private let refused: AsyncStream<Refusal>.Continuation

  public init() {
    (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    (refusals, refused) = AsyncStream.makeStream(of: Refusal.self)
  }

  public func serves(_ adbSerial: String, as id: DeviceID) -> Bool {
    let (serve, report) = state.withLock { state -> (Bool, Bool) in
      guard state.loaded, let locations = state.locations, state.unsettled[adbSerial] == nil
      else { return (false, false) }
      if state.vouched[id]?.contains(adbSerial) == true { return (true, false) }
      let mdnsName =
        adbSerial.hasPrefix("adb-\(id.serial)-") && adbSerial.hasSuffix("._adb-tls-connect._tcp")
      if state.paired.contains(id), mdnsName { return (true, false) }
      if Self.isLocated(id, in: locations) {
        return (false, state.reported.insert(adbSerial).inserted)
      }
      return (locations.complete && state.vouched[id] == nil, false)
    }
    if report { refused.yield(Refusal(adbSerial: adbSerial, id: id)) }
    return serve
  }

  /// Whether Ferry has a Finder location for `id`: one whose storage names the device, or, for
  /// one adopted at start and known only by identifier, the identifier of its internal storage
  /// (see `DomainController.location(of:)`).
  private static func isLocated(_ id: DeviceID, in locations: Locations) -> Bool {
    locations.devices.contains(id)
      || DomainController.internalKeys.contains {
        locations.identifiers.contains(
          DomainNaming.identifier(for: StorageID(device: id, key: $0)))
      }
  }

  /// The domain controller's current locations.
  func locate(identifiers: Set<String>, devices: Set<DeviceID>, complete: Bool) {
    state.withLock {
      $0.locations = Locations(identifiers: identifiers, devices: devices, complete: complete)
    }
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
