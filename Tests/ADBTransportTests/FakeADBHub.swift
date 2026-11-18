import Foundation
import os

@testable import ADBTransport

/// An adb server with several devices on it, for the transport: it lists them
/// (`host:devices-l`), streams changes (`host:track-devices-l`) and routes every other
/// connection to the `FakeAndroid` behind the serial it names. It can be killed and started
/// again on the same port, as `adb kill-server` and a restart would.
final class FakeADBHub: Sendable {
  /// One line of adb's device list. A device reachable two ways (USB and Wi-Fi) has two.
  struct Entry: Sendable {
    let serial: String
    let state: String
    let model: String?
    let device: FakeAndroid?

    init(_ serial: String, _ state: String = "device", model: String? = nil, device: FakeAndroid?) {
      self.serial = serial
      self.state = state
      self.model = model
      self.device = device
    }
  }

  private struct State {
    var entries: [Entry] = []
    var server: FakeADBServer?
    var trackers: [UUID: AsyncStream<String>.Continuation] = [:]
    var deviceListings = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  init(_ entries: [Entry] = []) {
    state.withLock { $0.entries = entries }
  }

  /// The port the server listens on; the same across restarts.
  var port: UInt16 { state.withLock { $0.server?.port ?? 0 } }

  /// How many `host:devices-l` queries the server answered.
  var deviceListings: Int { state.withLock { $0.deviceListings } }

  /// Starts the server on `port`, or on a free port the first time.
  func start(port: UInt16? = nil) async throws {
    let server = try await FakeADBServer.start(port: port) { [self] peer in
      try await self.handle(peer)
    }
    state.withLock { $0.server = server }
  }

  /// Stops the server as `adb kill-server` does: the port closes and so does every connection.
  func kill() async {
    let (server, trackers, devices) = state.withLock { state in
      defer {
        state.server = nil
        state.trackers = [:]
      }
      return (state.server, Array(state.trackers.values), state.entries.compactMap(\.device))
    }
    await server?.stopAndWait()
    for tracker in trackers { tracker.finish() }
    for device in devices { device.dropConnections() }
  }

  /// Replaces the device list and tells every tracking client.
  func set(_ entries: [Entry]) {
    let (listing, trackers) = state.withLock { state in
      state.entries = entries
      return (Self.listing(entries), Array(state.trackers.values))
    }
    for tracker in trackers { tracker.yield(listing) }
  }

  private static func listing(_ entries: [Entry]) -> String {
    entries.map { entry in
      [entry.serial, entry.state, entry.model.map { "model:\($0)" }].compactMap { $0 }
        .joined(separator: " ") + "\n"
    }.joined()
  }

  private func handle(_ peer: FakeADBServer.Peer) async throws {
    let first = try await peer.request()
    switch first {
    case "host:devices-l":
      let listing = state.withLock { state in
        state.deviceListings += 1
        return Self.listing(state.entries)
      }
      try await peer.answer(listing)
    case "host:track-devices-l":
      try await track(peer)
    default:
      let serial = Self.serial(in: first)
      let device = state.withLock { state in
        state.entries.first { $0.serial == serial && $0.state == "device" }?.device
      }
      guard let serial, let device else {
        try await peer.fail("device '\(serial ?? first)' not found")
        return
      }
      try await device.handle(peer, serial: serial, first: first)
    }
  }

  private func track(_ peer: FakeADBServer.Peer) async throws {
    let id = UUID()
    let (updates, continuation) = AsyncStream.makeStream(of: String.self)
    let current = state.withLock { state in
      state.trackers[id] = continuation
      return Self.listing(state.entries)
    }
    defer { _ = state.withLock { $0.trackers.removeValue(forKey: id) } }
    try await peer.okay()
    try await peer.send(String(data: try ADBWire.frame(current), encoding: .utf8) ?? "")
    for await listing in updates {
      try await peer.send(String(data: try ADBWire.frame(listing), encoding: .utf8) ?? "")
    }
  }

  /// The serial a routed request names: `host-serial:<serial>:features` or
  /// `host:transport:<serial>`.
  private static func serial(in request: String) -> String? {
    if request.hasPrefix("host:transport:") {
      return String(request.dropFirst("host:transport:".count))
    }
    if request.hasPrefix("host-serial:"), request.hasSuffix(":features") {
      return String(request.dropFirst("host-serial:".count).dropLast(":features".count))
    }
    return nil
  }
}
