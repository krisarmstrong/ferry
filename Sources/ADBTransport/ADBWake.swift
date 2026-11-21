import DeviceKit
import Foundation

/// Reads `dumpsys power` for the display's state.
enum ADBWake {
  enum Display: Equatable {
    case lit
    /// Off, dozing, or any other state but on.
    case dark
  }

  /// How long a wake waits between two reads of `dumpsys power`.
  static let readInterval = Duration.milliseconds(100)

  /// The display's state from `dumpsys power`'s `Display Power: state=<STATE>` line; `nil` when
  /// there is no such line, which no later read will change.
  static func display(fromDumpsysPower text: String) -> Display? {
    let prefix = "Display Power: state="
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(prefix) else { continue }
      let state = trimmed.dropFirst(prefix.count)
      guard !state.isEmpty else { return nil }
      return state == "ON" ? .lit : .dark
    }
    return nil
  }
}

extension ADBDeviceTools {
  /// Sends `KEYCODE_WAKEUP`, which turns the display on and leaves one that is on alone, then
  /// reads `dumpsys power`, every 100 ms, until it reports the display on, for at most
  /// `wakeLimit`. A device that prints no display state is not read again. A unit
  /// whose display is off captures a black screen. The key has the usual answer limit of its
  /// own: `input` starts a runtime and can take longer than the display does. Returns whether
  /// the display came on; a device that refuses the key, or does not answer, is not waited for
  /// further, and the caller captures anyway.
  public func wakeScreen(route: ADBRoute) async -> Bool {
    let (host, keyLimit, clock) = (host, answerLimit, clock)
    do throws(ADBError) {
      let key = try ADBShell.command("input", ["keyevent", "KEYCODE_WAKEUP"])
      let power = try ADBShell.command("dumpsys", ["power"])
      let pressed = try await ADBTransport.within(keyLimit, on: clock) {
        () async throws(ADBError) in
        try await host.run(route: route, command: key).status == 0
      }
      guard pressed else { return false }
      let (limit, pause) = (wakeLimit, pause)
      // Bounded twice: by the paced waits, and in time, for a read that never answers.
      return try await ADBTransport.within(limit, on: clock) { () async throws(ADBError) -> Bool in
        var waited = Duration.zero
        while true {
          let result = try await host.run(route: route, command: power)
          guard result.status == 0 else { return false }
          switch ADBWake.display(fromDumpsysPower: Self.text(result.stdout)) {
          case .lit: return true
          case nil: return false
          case .dark: break
          }
          guard waited + ADBWake.readInterval <= limit else { return false }
          do {
            try await pause(ADBWake.readInterval)
          } catch {
            throw .cancelled
          }
          waited += ADBWake.readInterval
        }
      }
    } catch {
      Self.log.info("waking the screen: \(String(describing: error), privacy: .private)")
      return false
    }
  }
}
