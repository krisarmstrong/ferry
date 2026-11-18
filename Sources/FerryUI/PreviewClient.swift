import DeviceKit
import FerryIPC
import Foundation

/// A fixed agent for SwiftUI previews.
struct PreviewClient: AgentSending {
  static let ready = AttachedDevice(
    info: DeviceInfo(
      id: DeviceID(serial: "LR1"), manufacturer: "NetAlly", model: "LinkRunner-100G"),
    state: .ready([
      StorageInfo(
        id: StorageID(device: DeviceID(serial: "LR1"), key: "Internal shared storage|0"),
        description: "Internal shared storage", capacity: 64_000_000_000, free: 41_500_000_000)
    ]))
  static let notSharing = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "ES1"), manufacturer: "NetAlly", model: "EtherScope nXG"),
    state: .notSharingFiles)
  static let busy = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "PX1"), manufacturer: "Google", model: "Pixel 8"),
    state: .busy)
  static let failed = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "GX1"), manufacturer: "Samsung", model: "Galaxy S24"),
    state: .failed(.io("LIBMTP_Get_Storage failed")))

  let devices: [AttachedDevice]
  let providerEnabled: Bool

  func send(_ request: AgentRequest, file: FileHandle?) async throws(TransportError)
    -> AgentResponse
  {
    switch request {
    case .status: .status(devices: devices, providerEnabled: providerEnabled)
    default: .done
    }
  }
}

extension AppModel {
  static func preview(_ devices: [AttachedDevice], providerEnabled: Bool = true) -> AppModel {
    AppModel(
      client: PreviewClient(devices: devices, providerEnabled: providerEnabled),
      services: PreviewServices())
  }
}

@MainActor
private final class PreviewServices: SystemServicing {
  var opensAtLogin = false
  func setOpensAtLogin(_ enabled: Bool) { opensAtLogin = enabled }
  func unregisterAgent() {}
  func open(_ url: URL) {}
  func reveal(_ urls: [URL]) {}
  func quit() {}
}
