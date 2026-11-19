import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Waking the screen before a capture: `input keyevent KEYCODE_WAKEUP`, then `dumpsys power`
/// read until it reports the display on, for at most the wake limit. A device that refuses is
/// captured anyway.
@Suite(.timeLimit(.minutes(1)))
struct ADBWakeTests {
  static let serial = "0123456789abcdef"

  /// The part of `dumpsys power` Android 8.1 prints about the display.
  static func power(_ state: String) -> String {
    """
    POWER MANAGER (dumpsys power)

    Power Manager State:
      mDirty=0x0
      mWakefulness=\(state == "ON" ? "Awake" : "Asleep")
      mWakefulnessChanging=false
      mIsPowered=true
    Display Power: state=\(state)
    """
  }

  @Test(arguments: [("ON", true), ("OFF", false), ("DOZE", false), ("UNKNOWN", false)])
  func theDisplayIsOnOnlyWhenPowerSaysSo(state: String, isOn: Bool) {
    #expect(ADBWake.displayIsOn(fromDumpsysPower: Self.power(state)) == isOn)
  }

  @Test func textWithoutTheDisplayLineIsNotOn() {
    #expect(!ADBWake.displayIsOn(fromDumpsysPower: ""))
    #expect(!ADBWake.displayIsOn(fromDumpsysPower: "Display Power: state=ONLY"))
  }

  private func withTools<T>(
    _ device: FakeAndroid, wakeLimit: Duration = .seconds(5),
    _ body: (ADBDeviceTools) async throws -> T
  ) async throws -> T {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    let tools = ADBDeviceTools(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), answerLimit: .seconds(5),
      captureLimit: ADBDeviceTools.defaultCaptureLimit, captureWait: .seconds(5),
      wakeLimit: wakeLimit)
    return try await body(tools)
  }

  /// The key wakes the display after the device's own delay: power is read until it says so,
  /// and not after.
  @Test func theWakeWaitsForTheDisplay() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.displayOn = false
      $0.displayOnAfterPolls = 3
    }
    let woke = try await withTools(device) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(woke)
    let commands = device.commands
    #expect(commands.first == ["input", "keyevent", "KEYCODE_WAKEUP"])
    #expect(commands.dropFirst().allSatisfy { $0 == ["dumpsys", "power"] })
    #expect(commands.count == 4)
  }

  /// A display already on is read once.
  @Test func aDisplayAlreadyOnIsReadOnce() async throws {
    let device = FakeAndroid()
    let woke = try await withTools(device) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(woke)
    #expect(device.commands == [["input", "keyevent", "KEYCODE_WAKEUP"], ["dumpsys", "power"]])
  }

  /// A display that never comes on is given up at the limit.
  @Test func aDisplayThatStaysOffIsGivenUpAtTheLimit() async throws {
    let device = FakeAndroid()
    device.setTools { $0.displayOn = false }
    let start = ContinuousClock.now
    let woke = try await withTools(device, wakeLimit: .milliseconds(300)) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(!woke)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  /// A device that refuses the key is not read at all: the capture goes ahead at once.
  @Test func aRefusedKeyIsNotWaitedFor() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.displayOn = false
      $0.wakeRefused = true
    }
    let woke = try await withTools(device) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(!woke)
    #expect(device.commands == [["input", "keyevent", "KEYCODE_WAKEUP"]])
  }

  /// A device that hangs on the key is given up at the limit too.
  @Test func aHangingKeyIsGivenUpAtTheLimit() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.hangingPrograms = ["input"] }
    let woke = try await withTools(device, wakeLimit: .milliseconds(300)) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(!woke)
  }
}
