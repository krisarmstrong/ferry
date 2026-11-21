import DeviceKit
import DeviceKitTestSupport
import Foundation
import Synchronization
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

  @Test(arguments: [
    ("ON", ADBWake.Display.lit), ("OFF", .dark), ("DOZE", .dark), ("UNKNOWN", .dark),
  ])
  func theDisplayIsWhatPowerSays(state: String, display: ADBWake.Display) {
    #expect(ADBWake.display(fromDumpsysPower: Self.power(state)) == display)
  }

  /// No display line, or a state Ferry cannot read, says nothing about the display.
  @Test func textWithoutTheDisplayLineSaysNothing() {
    #expect(ADBWake.display(fromDumpsysPower: "") == nil)
    #expect(ADBWake.display(fromDumpsysPower: "mWakefulness=Awake\n") == nil)
    #expect(ADBWake.display(fromDumpsysPower: "Display Power: state=") == nil)
  }

  /// The limits are measured on `clock`, which stands still unless the test moves it; the paced
  /// waits between reads return at once.
  private func withTools<T>(
    _ device: FakeAndroid, answerLimit: Duration = .seconds(5), wakeLimit: Duration = .seconds(5),
    pauses: Pauses = Pauses(), clock: ManualClock = ManualClock(),
    _ body: (ADBDeviceTools) async throws -> T
  ) async throws -> T {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    let tools = ADBDeviceTools(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), answerLimit: answerLimit,
      captureLimit: ADBDeviceTools.defaultCaptureLimit, captureWait: .seconds(5),
      wakeLimit: wakeLimit, pause: { pauses.record($0) }, clock: clock)
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

  /// A read of the display that never answers is given up at the wake limit, in time: the paced
  /// bound alone would wait on it forever.
  @Test func aReadThatNeverAnswersIsGivenUpAtTheLimit() async throws {
    let device = FakeAndroid()
    device.setTools { $0.displayOn = false }
    device.state.withLock { $0.hangingPrograms = ["dumpsys"] }
    let clock = ManualClock()
    let limit = Duration.milliseconds(300)
    let woke = try await withTools(device, wakeLimit: limit, clock: clock) { tools in
      let waking = Task { await tools.wakeScreen(route: ADBRoute(serial: Self.serial)) }
      await device.waitForHangs(1)
      return await clock.advancing(by: limit) { await waking.value }
    }
    #expect(!woke)
    // One read, never answered and never repeated.
    #expect(device.state.withLock { $0.hangs } == 1)
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

  /// The key has its own bound, the device's usual answer limit: `input` starts a runtime and can
  /// take longer than the display does, and the 2 s are for the display alone.
  @Test func aHangingKeyIsGivenUpAtTheAnswerLimit() async throws {
    let device = FakeAndroid()
    device.state.withLock { $0.hangingPrograms = ["input"] }
    let clock = ManualClock()
    let limits = (answer: Duration.milliseconds(300), wake: Duration.seconds(10))
    let woke = try await withTools(
      device, answerLimit: limits.answer, wakeLimit: limits.wake, clock: clock
    ) { tools in
      async let woke = tools.wakeScreen(route: ADBRoute(serial: Self.serial))
      await device.waitForHangs(1)
      await clock.waitForSleeper()
      await clock.advance(by: limits.answer)
      return await woke
    }
    #expect(!woke)
    #expect(!device.commands.contains(["dumpsys", "power"]))
  }

  /// Re-reads are paced on the injected clock, 100 ms apart, never back to back.
  @Test func readsArePaced() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.displayOn = false
      $0.displayOnAfterPolls = 3
    }
    let pauses = Pauses()
    let woke = try await withTools(device, pauses: pauses) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(woke)
    #expect(pauses.all == [.milliseconds(100), .milliseconds(100)])
  }

  /// A display that stays off is read until the paced waits would pass the limit.
  @Test func aDisplayThatStaysOffIsReadUntilTheLimit() async throws {
    let device = FakeAndroid()
    device.setTools { $0.displayOn = false }
    let pauses = Pauses()
    let woke = try await withTools(device, wakeLimit: .milliseconds(300), pauses: pauses) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(!woke)
    // The waits reach the limit, and each read but the first follows one.
    #expect(pauses.all == Array(repeating: .milliseconds(100), count: 3))
    #expect(device.commands.filter { $0 == ["dumpsys", "power"] }.count == 4)
  }

  /// A device whose `dumpsys power` has no display line will never say the display is on, so
  /// the capture goes ahead after one read.
  @Test func noDisplayLineStopsAtOnce() async throws {
    let device = FakeAndroid()
    device.setTools { $0.powerText = "Power Manager State:\n  mDirty=0x0\n" }
    let pauses = Pauses()
    let woke = try await withTools(device, pauses: pauses) {
      await $0.wakeScreen(route: ADBRoute(serial: Self.serial))
    }
    #expect(!woke)
    #expect(pauses.all.isEmpty)
    #expect(device.commands.filter { $0 == ["dumpsys", "power"] }.count == 1)
  }
}

/// The waits a wake asked for, which return at once.
final class Pauses: Sendable {
  private let waits = Mutex<[Duration]>([])
  var all: [Duration] { waits.withLock { $0 } }
  func record(_ duration: Duration) { waits.withLock { $0.append(duration) } }
}
