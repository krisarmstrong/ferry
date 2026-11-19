import DeviceKit
import Foundation

/// A screen recording the agent is running, for the menu's indicator.
public struct ActiveRecording: Codable, Sendable, Equatable {
  public let device: DeviceID
  public let started: Date
  /// Stop was asked for; the recording is being finished.
  public let stopping: Bool
  /// The recording has ended and waits on the device for the app to collect it with
  /// `.saveRecording`.
  public let finished: Bool

  public init(device: DeviceID, started: Date, stopping: Bool, finished: Bool = false) {
    self.device = device
    self.started = started
    self.stopping = stopping
    self.finished = finished
  }
}

/// Why a tool (APK install, screenshot, screen recording) did not do what was asked, for the
/// user. A lost device is `.failure(.deviceDisconnected)` instead, as for files.
public enum ToolFailure: Error, Codable, Sendable, Equatable {
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
  /// The device sent more than any real recording; it was deleted.
  case recordingTooLarge
  /// The device stopped sending the recording; it is kept on the device for another try.
  case recordingStalled
  /// The recording is still being finished or saved.
  case recordingBusy
  /// The app could not create the file where macOS saves screenshots, nor on the Desktop.
  case cannotSave
  /// A port forward needs a port on the Mac from 1024 to 65535 and one on the device from 1 to
  /// 65535.
  case invalidPort
  /// adb refused a forward (the port is taken, say): adb's own words.
  case forwardFailed(String)
  /// The forward to remove is not there (another tool removed it first).
  case forwardNotFound
  /// Ferry could not find the `adb` program, which a shell in Terminal runs.
  case adbNotFound
}

/// Lines of a device's log the agent sends in one go, on the reverse channel (see
/// `AgentClientXPC.logBatch`). Lines are text: bytes that are not UTF-8 arrive as replacement
/// characters, and a line is at most a few KB.
public struct LogBatch: Codable, Sendable, Equatable {
  public let lines: [String]
  /// Lines the agent dropped before these because the app was not taking them fast enough.
  public let skipped: Int

  public init(lines: [String], skipped: Int) {
    self.lines = lines
    self.skipped = skipped
  }
}

/// How the agent sends a batch of log lines to the client that asked for them. Answers whether
/// the client wants more: `false` once it has gone away or stopped listening, which ends the
/// stream.
public typealias LogSink = @Sendable (LogBatch) async -> Bool

/// How a client takes a batch of log lines. It returns once the batch is in, which paces the
/// agent: it sends the next batch only after this one is taken.
public typealias LogBatchHandler = @Sendable (LogBatch) async -> Void

/// What Open Shell needs to run `adb -s <serial> shell` in Terminal: the `adb` the agent found
/// and the serial of the route it serves the device by.
///
/// Both end up in a command line, so each is checked: the path must be absolute and free of
/// control characters, and the serial limited to the characters adb itself gives serials
/// (letters, digits, `.`, `_`, `-` and `:`), not starting with `-`, which adb would read as an
/// option. A reply that fails the check does not decode.
public struct ShellTarget: Codable, Sendable, Equatable {
  public let adb: String
  public let serial: String
  /// The adb server's connection to the unit (`transport_id`), when adb reports one: the shell
  /// then selects the unit by it (`adb -t`), so it never reaches another unit that took the
  /// address since. Digits only.
  public let transportID: String?

  public init?(adb: String, serial: String, transportID: String? = nil) {
    guard Self.isValid(adb: adb), Self.isValid(serial: serial),
      transportID.map(Self.isValid(transportID:)) != false
    else { return nil }
    self.adb = adb
    self.serial = serial
    self.transportID = transportID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let adb = try container.decode(String.self, forKey: .adb)
    let serial = try container.decode(String.self, forKey: .serial)
    let transportID = try container.decodeIfPresent(String.self, forKey: .transportID)
    guard let target = ShellTarget(adb: adb, serial: serial, transportID: transportID) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid shell target"))
    }
    self = target
  }

  static func isValid(adb path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count <= 1024
      && path.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }

  static func isValid(transportID: String) -> Bool {
    (1...20).contains(transportID.utf8.count)
      && transportID.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
  }

  static func isValid(serial: String) -> Bool {
    (1...128).contains(serial.utf8.count) && serial.first != "-"
      && serial.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || ".-_:".unicodeScalars.contains($0)
      }
  }
}
