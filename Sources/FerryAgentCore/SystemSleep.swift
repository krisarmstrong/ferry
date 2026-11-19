import Foundation
import IOKit
import IOKit.pwr_mgt
import Synchronization
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "SystemSleep")

/// The Mac's sleep and wake, from IOKit's system power notifications on a dispatch queue of
/// their own, so they arrive in a process with no run loop (the agent parks in `dispatchMain`).
public enum SystemSleep {
  // `iokit_common_msg(0x270)`, `(0x280)` and `(0x300)`, which Swift does not import.
  static let canSleep: UInt32 = 0xE000_0270
  static let willSleep: UInt32 = 0xE000_0280
  static let hasPoweredOn: UInt32 = 0xE000_0300

  /// `true` when the Mac is about to sleep, `false` once it has woken, for the rest of the
  /// process. Empty if the notifications cannot be registered (logged).
  public static func states() -> AsyncStream<Bool> {
    let (states, continuation) = AsyncStream.makeStream(of: Bool.self)
    // Lives as long as the process: the notifications never stop.
    let watcher = Unmanaged.passRetained(PowerWatcher(continuation: continuation))
    var notifier: io_object_t = 0
    var port: IONotificationPortRef?
    let root = IORegisterForSystemPower(watcher.toOpaque(), &port, powerChanged, &notifier)
    guard root != 0, let port else {
      log.error("could not register for system power notifications")
      watcher.release()
      continuation.finish()
      return states
    }
    watcher.takeUnretainedValue().root.store(root, ordering: .releasing)
    IONotificationPortSetDispatchQueue(
      port, DispatchQueue(label: "io.github.krisarmstrong.ferry.system-sleep"))
    return states
  }
}

/// What the power callback reaches through its refcon.
private final class PowerWatcher: Sendable {
  let continuation: AsyncStream<Bool>.Continuation
  /// The root power domain connection, which every sleep notice must be answered on.
  let root = Atomic<io_connect_t>(0)

  init(continuation: AsyncStream<Bool>.Continuation) {
    self.continuation = continuation
  }
}

/// Lets the Mac sleep without delay (IOKit waits for an answer to each notice), and reports the
/// sleep and the wake.
private func powerChanged(
  _ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ message: UInt32,
  _ argument: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let watcher = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
  let root = watcher.root.load(ordering: .acquiring)
  switch message {
  case SystemSleep.canSleep:
    IOAllowPowerChange(root, Int(bitPattern: argument))
  case SystemSleep.willSleep:
    log.info("the Mac is going to sleep: pausing the change watch")
    watcher.continuation.yield(true)
    IOAllowPowerChange(root, Int(bitPattern: argument))
  case SystemSleep.hasPoweredOn:
    log.info("the Mac woke: resuming the change watch")
    watcher.continuation.yield(false)
  default:
    break
  }
}
