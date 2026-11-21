import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

extension WirelessADB {
  /// adb's words, unless they are the "No route to host" macOS gives a program it denies the
  /// local network: a device the user could otherwise reach would look unreachable. The agent
  /// connects itself to tell. Denied too, the user is asked to allow Ferry. Reached, the server
  /// is the one cut off, an earlier agent's left running, and it is replaced
  /// (`.serverRestarted`); the caller tries once more on the new one, and the remembered devices
  /// reconnect when it comes up.
  func failure(reaching endpoint: WirelessEndpoint, _ detail: String) async -> WirelessFailure {
    guard detail.contains("No route to host") else { return .adb(detail) }
    switch await localNetwork(endpoint) {
    case .denied:
      log.error("macOS denies Ferry the local network: \(endpoint.argument, privacy: .private)")
      return .localNetworkDenied
    case .reached:
      guard await replaceCutOffServer() else { return .adb(detail) }
      log.notice("replaced an adb server cut off from \(endpoint.argument, privacy: .private)")
      return .serverRestarted
    case .unknown:
      return .adb(detail)
    }
  }

  /// Waits, up to `timing.settle`, for adb's server to answer again after a replacement.
  func serverAnswers() async -> Bool {
    let deadline = ContinuousClock.now + timing.settle
    while ContinuousClock.now < deadline {
      if (try? await adb.devices()) != nil { return true }
      try? await Task.sleep(for: timing.poll)
    }
    return false
  }
}
