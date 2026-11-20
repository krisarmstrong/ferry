import DeviceKit
import FerryIPC
import Foundation
import PlatformTools

/// A fixed agent for SwiftUI previews.
struct PreviewClient: AgentSending {
  static let ready = AttachedDevice(
    info: DeviceInfo(
      id: DeviceID(serial: "LR1"), manufacturer: "NetAlly", model: "LinkRunner-100G"),
    state: .ready([
      StorageInfo(
        id: StorageID(device: DeviceID(serial: "LR1"), key: "Internal shared storage|0"),
        description: "Internal shared storage", capacity: 64_000_000_000, free: 41_500_000_000)
    ]), method: .usbFileTransfer)
  static let readyOverADB = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "LR2"), manufacturer: "NetAlly", model: "LinkRunner 10G"),
    state: .ready([]), method: .usbADB)
  static let readyOverWiFi = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "ES2"), manufacturer: "NetAlly", model: "EtherScope nXG"),
    state: .ready([]), method: .wifiADB)
  static let notSharing = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "ES1"), manufacturer: "NetAlly", model: "EtherScope nXG"),
    state: .notSharingFiles, method: .usbFileTransfer)
  static let busy = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "PX1"), manufacturer: "Google", model: "Pixel 8"),
    state: .busy, method: .usbFileTransfer)
  static let failed = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "GX1"), manufacturer: "Samsung", model: "Galaxy S24"),
    state: .failed(.io("LIBMTP_Get_Storage failed")), method: .usbFileTransfer)

  let devices: [AttachedDevice]
  let provider: ProviderState
  let adb: ADBStatus?

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError)
    -> AgentResponse
  {
    switch request {
    case .status: .status(StatusReport(devices: devices, provider: provider, adbStatus: adb))
    default: .done
    }
  }
}

extension AppModel {
  static func preview(
    _ devices: [AttachedDevice], provider: ProviderState = .enabled, adb: ADBStatus? = nil
  ) -> AppModel {
    AppModel(
      client: PreviewClient(devices: devices, provider: provider, adb: adb),
      services: PreviewServices())
  }
}

@MainActor
private final class PreviewServices: SystemServicing {
  func registerAgent() async {}
  func agentBuild() -> String? { nil }
  func startedAgentBuild() -> String? { nil }
  func recordStartedAgent(_ build: String) {}
  func restartAgent() async -> Bool { true }
  func helperStatus() async -> HelperStatus { .allowed }
  func loginItemStatus() async -> LoginItemStatus { .disabled }
  func setOpensAtLogin(_ enabled: Bool) async {}
  func unregisterAgent() {}
  func open(_ url: URL) {}
  func reveal(_ urls: [URL]) {}
  func quit() {}
  func appWasReplaced() -> Bool { false }
  func relaunch() {}
  func copy(_ text: String) {}
  func announce(_ text: String) {}
  func chooseAPK() async -> URL? { nil }
  func chooseFilesToSend() async -> [URL] { [] }
  func captureFolders() -> [URL] { [] }
  func chooseFolder() async -> URL? { nil }
  func chooseLogDestination(suggestedName: String) async -> URL? { nil }
  func openInTerminal(_ script: URL) async -> Bool { false }
  func platformToolsAcceptance() -> LicenseAcceptance? { nil }
  func recordPlatformToolsAcceptance(_ acceptance: LicenseAcceptance) {}
  func fetchedPlatformToolsVersion() -> String? { nil }
  func fetchPlatformTools(accepted: LicenseAcceptance?) async throws(PlatformToolsError) {}
}
