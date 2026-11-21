import DeviceKit
import FerryIPC
import Foundation

/// One sample of every case of the errors the menu words, for `HelpLinkTests`. Each enum gets a
/// case-name enum and two switches with no `default`: a case added to the error fails to compile
/// in `kind(of:)` until it is named here, and then in `sample(_:)` until it has a sample.
enum HelpLinkCases {
  private static let path = RemotePath.root

  enum Transport: CaseIterable {
    case noDeviceConnected, deviceNotFound, noStorage, storageNotFound, deviceBusy, deviceLocked
    case deviceDisconnected, notFound, unknownItem, alreadyExists, invalidName, unsupported
    case insufficientSpace, fileTooLargeForStorage, sizeMismatch, downloadSizeMismatch
    case nameChangedByDevice, directoryNotEmpty, changedOnDevice, macDiskFull, folderTooDeep
    case readOnly, cancelled, agentNotResponding, io
  }

  static func kind(of error: TransportError) -> Transport {
    switch error {
    case .noDeviceConnected: .noDeviceConnected
    case .deviceNotFound: .deviceNotFound
    case .noStorage: .noStorage
    case .storageNotFound: .storageNotFound
    case .deviceBusy: .deviceBusy
    case .deviceLocked: .deviceLocked
    case .deviceDisconnected: .deviceDisconnected
    case .notFound: .notFound
    case .unknownItem: .unknownItem
    case .alreadyExists: .alreadyExists
    case .invalidName: .invalidName
    case .unsupported: .unsupported
    case .insufficientSpace: .insufficientSpace
    case .fileTooLargeForStorage: .fileTooLargeForStorage
    case .sizeMismatch: .sizeMismatch
    case .downloadSizeMismatch: .downloadSizeMismatch
    case .nameChangedByDevice: .nameChangedByDevice
    case .directoryNotEmpty: .directoryNotEmpty
    case .changedOnDevice: .changedOnDevice
    case .macDiskFull: .macDiskFull
    case .folderTooDeep: .folderTooDeep
    case .readOnly: .readOnly
    case .cancelled: .cancelled
    case .agentNotResponding: .agentNotResponding
    case .io: .io
    }
  }

  static func sample(_ kind: Transport) -> TransportError {
    switch kind {
    case .noDeviceConnected: .noDeviceConnected
    case .deviceNotFound: .deviceNotFound(DeviceID(serial: "A"))
    case .noStorage: .noStorage
    case .storageNotFound: .storageNotFound("internal")
    case .deviceBusy: .deviceBusy
    case .deviceLocked: .deviceLocked
    case .deviceDisconnected: .deviceDisconnected
    case .notFound: .notFound(path)
    case .unknownItem: .unknownItem
    case .alreadyExists: .alreadyExists(path)
    case .invalidName: .invalidName("a:b")
    case .unsupported: .unsupported("move")
    case .insufficientSpace: .insufficientSpace(needed: 2, free: 1)
    case .fileTooLargeForStorage: .fileTooLargeForStorage(size: 5_000_000_000)
    case .sizeMismatch: .sizeMismatch(expected: 2, actual: 1)
    case .downloadSizeMismatch: .downloadSizeMismatch(listed: 2, received: 1)
    case .nameChangedByDevice: .nameChangedByDevice(requested: "a", actual: "b")
    case .directoryNotEmpty: .directoryNotEmpty(path)
    case .changedOnDevice: .changedOnDevice(path)
    case .macDiskFull: .macDiskFull(needed: 2, free: 1)
    case .folderTooDeep: .folderTooDeep(path)
    case .readOnly: .readOnly(path)
    case .cancelled: .cancelled
    case .agentNotResponding: .agentNotResponding
    case .io: .io("broken pipe")
    }
  }

  enum Tool: CaseIterable {
    case notOverADB, notAnAPK, apkTooLarge, installFailed, alreadyRecording, notRecording
    case noImage, recordingFailed, recordingTooLarge, recordingStalled, recordingBusy, cannotSave
    case invalidPort, forwardFailed, forwardNotFound, adbNotFound
  }

  static func kind(of failure: ToolFailure) -> Tool {
    switch failure {
    case .notOverADB: .notOverADB
    case .notAnAPK: .notAnAPK
    case .apkTooLarge: .apkTooLarge
    case .installFailed: .installFailed
    case .alreadyRecording: .alreadyRecording
    case .notRecording: .notRecording
    case .noImage: .noImage
    case .recordingFailed: .recordingFailed
    case .recordingTooLarge: .recordingTooLarge
    case .recordingStalled: .recordingStalled
    case .recordingBusy: .recordingBusy
    case .cannotSave: .cannotSave
    case .invalidPort: .invalidPort
    case .forwardFailed: .forwardFailed
    case .forwardNotFound: .forwardNotFound
    case .adbNotFound: .adbNotFound
    }
  }

  /// Every sample of `kind`: an install and a recording fail in more than one wording.
  static func samples(_ kind: Tool) -> [ToolFailure] {
    switch kind {
    case .notOverADB: [.notOverADB]
    case .notAnAPK: [.notAnAPK]
    case .apkTooLarge: [.apkTooLarge]
    case .installFailed:
      [
        .installFailed("INSTALL_FAILED_OLDER_SDK"),
        .installFailed("INSTALL_PARSE_FAILED_NO_CERTIFICATES"), .installFailed("SOMETHING_NEW"),
      ]
    case .alreadyRecording: [.alreadyRecording]
    case .notRecording: [.notRecording]
    case .noImage: [.noImage]
    case .recordingFailed: [.recordingFailed(""), .recordingFailed("encoder died")]
    case .recordingTooLarge: [.recordingTooLarge]
    case .recordingStalled: [.recordingStalled]
    case .recordingBusy: [.recordingBusy]
    case .cannotSave: [.cannotSave]
    case .invalidPort: [.invalidPort]
    case .forwardFailed: [.forwardFailed("Address already in use")]
    case .forwardNotFound: [.forwardNotFound]
    case .adbNotFound: [.adbNotFound]
    }
  }

  enum Outcome: CaseIterable {
    case connected, awaitingAllow, needsConfirmation, needsNetwork
    case adbUnavailable, notOverUSB, notRemembered, noConnectService, otherDevice, unidentified
    case pairingNeedsAddress, offerChanged, deviceInUse, localNetworkDenied, serverRestarted, adb
  }

  static func kind(of outcome: WirelessOutcome) -> Outcome {
    switch outcome {
    case .connected: .connected
    case .awaitingAllow: .awaitingAllow
    case .needsConfirmation: .needsConfirmation
    case .needsNetwork: .needsNetwork
    case .failed(let failure):
      switch failure {
      case .adbUnavailable: .adbUnavailable
      case .notOverUSB: .notOverUSB
      case .notRemembered: .notRemembered
      case .noConnectService: .noConnectService
      case .otherDevice: .otherDevice
      case .unidentified: .unidentified
      case .pairingNeedsAddress: .pairingNeedsAddress
      case .offerChanged: .offerChanged
      case .deviceInUse: .deviceInUse
      case .localNetworkDenied: .localNetworkDenied
      case .serverRestarted: .serverRestarted
      case .adb: .adb
      }
    }
  }

  static func sample(_ kind: Outcome, address: WirelessEndpoint) -> WirelessOutcome {
    switch kind {
    case .connected: .connected
    case .awaitingAllow: .awaitingAllow(address)
    case .needsConfirmation: .needsConfirmation(address)
    case .needsNetwork: .needsNetwork
    case .adbUnavailable: .failed(.adbUnavailable)
    case .notOverUSB: .failed(.notOverUSB)
    case .notRemembered: .failed(.notRemembered)
    case .noConnectService: .failed(.noConnectService)
    case .otherDevice: .failed(.otherDevice)
    case .unidentified: .failed(.unidentified)
    case .pairingNeedsAddress: .failed(.pairingNeedsAddress)
    case .offerChanged: .failed(.offerChanged)
    case .deviceInUse: .failed(.deviceInUse)
    case .localNetworkDenied: .failed(.localNetworkDenied)
    case .serverRestarted: .failed(.serverRestarted)
    case .adb: .failed(.adb("refused"))
    }
  }
}
