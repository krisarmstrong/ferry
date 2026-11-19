import DeviceKit
import Foundation

/// Reads `dumpsys power` for whether the display is on.
enum ADBWake {
  /// Whether `dumpsys power` reports the display on: its `Display Power: state=ON` line. Off,
  /// dozing, unknown, or no such line is not on.
  static func displayIsOn(fromDumpsysPower text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).contains {
      $0.trimmingCharacters(in: .whitespaces) == "Display Power: state=ON"
    }
  }
}

extension ADBDeviceTools {
  /// Sends `KEYCODE_WAKEUP`, which turns the display on and leaves one that is on alone, then
  /// reads `dumpsys power` until it reports the display on, for at most `wakeLimit` in all. A
  /// unit whose display is off captures a black screen. Returns whether the display came on; a
  /// device that refuses the key, or does not answer, is not waited for further, and the caller
  /// captures anyway.
  public func wakeScreen(route: ADBRoute) async -> Bool {
    let host = host
    do throws(ADBError) {
      let key = try ADBShell.command("input", ["keyevent", "KEYCODE_WAKEUP"])
      let power = try ADBShell.command("dumpsys", ["power"])
      return try await ADBTransport.within(wakeLimit) { () async throws(ADBError) -> Bool in
        guard try await host.run(route: route, command: key).status == 0 else { return false }
        // Each read is a round trip to the device, which paces the loop.
        while true {
          let result = try await host.run(route: route, command: power)
          guard result.status == 0 else { return false }
          if ADBWake.displayIsOn(fromDumpsysPower: Self.text(result.stdout)) { return true }
          if Task.isCancelled { throw .cancelled }
        }
      }
    } catch {
      Self.log.info("waking the screen: \(String(describing: error), privacy: .public)")
      return false
    }
  }
}
