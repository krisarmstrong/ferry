import DeviceKit
import Foundation

/// A screen recording the agent is running, for the menu's indicator.
public struct ActiveRecording: Codable, Sendable, Equatable {
  public let device: DeviceID
  public let started: Date
  /// Stop was asked for; the recording is being finished and saved.
  public let stopping: Bool

  public init(device: DeviceID, started: Date, stopping: Bool) {
    self.device = device
    self.started = started
    self.stopping = stopping
  }
}

/// Why a tool (APK install, screenshot, screen recording) did not do what was asked, for the
/// user. A lost device is `.failure(.deviceDisconnected)` instead, as for files.
public enum ToolFailure: Codable, Sendable, Equatable {
  /// The device is not served over ADB (USB debugging is off, or it is not ready).
  case notOverADB
  /// The file is not an Android app: no ZIP with an `AndroidManifest.xml`.
  case notAnAPK
  /// The file is larger than an APK can be (4 GB).
  case apkTooLarge
  /// pm refused the app: its code (`INSTALL_FAILED_…`), or its first line when it gave none.
  case installFailed(String)
  /// The device is already recording its screen.
  case alreadyRecording
  /// Stop was asked for a device that is not recording.
  case notRecording
  /// The device returned something other than an image.
  case noImage
  /// The recording produced no video; `screenrecord`'s own words, if it gave any.
  case recordingFailed(String)
  /// The file could not be written where macOS saves screenshots, nor on the Desktop.
  case cannotSave
}
