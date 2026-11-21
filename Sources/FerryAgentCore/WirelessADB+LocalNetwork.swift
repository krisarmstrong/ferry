import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "WirelessADB")

extension WirelessADB {
  /// adb's words, unless they are the "No route to host" macOS gives a program it denies the
  /// local network: a device the user could otherwise reach would look unreachable. The agent
  /// connects itself to tell. Denied too, the user is asked to allow Ferry. Reached, the server
  /// is the one cut off, an earlier agent's left running, and it is replaced; the remembered
  /// devices reconnect when the new one comes up.
  func failure(reaching endpoint: WirelessEndpoint, _ detail: String) async -> WirelessFailure {
    guard detail.contains("No route to host") else { return .adb(detail) }
    switch await localNetwork(endpoint) {
    case .denied:
      log.error("macOS denies Ferry the local network: \(endpoint.argument, privacy: .private)")
      return .localNetworkDenied
    case .reached:
      if await replaceCutOffServer() {
        log.notice("replaced an adb server cut off from \(endpoint.argument, privacy: .private)")
      }
      return .adb(detail)
    case .unknown:
      return .adb(detail)
    }
  }
}
