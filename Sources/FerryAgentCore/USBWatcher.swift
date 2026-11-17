import Dispatch
import IOKit
import IOKit.usb
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "USBWatcher")

/// Ticks whenever a USB device attaches or detaches, for `DeviceHub`'s `arrivals`.
public struct USBWatcher: Sendable {
  /// Ticks once when the notifications are armed, so a device plugged in after the hub's first
  /// listing but before then is not missed. Ticks that arrive faster than they are read
  /// coalesce into one.
  public static func ticks() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let monitor = USBMonitor(continuation: continuation)
    continuation.onTermination = { _ in
      Task { await monitor.stop() }
    }
    Task { await monitor.start() }
    return stream
  }
}

/// Holds the IOKit notification port. IOKit delivers notifications on a dispatch queue, so this
/// actor runs on that same queue: callbacks and teardown never overlap.
private actor USBMonitor {
  private let queue = DispatchSerialQueue(label: "io.github.krisarmstrong.ferry.usb-watcher")
  private let continuation: AsyncStream<Void>.Continuation
  private var port: IONotificationPortRef?
  private var iterators: [io_iterator_t] = []
  private var stopped = false

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(continuation: AsyncStream<Void>.Continuation) {
    self.continuation = continuation
  }

  func start() {
    guard !stopped, port == nil else { return }
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
      log.error("could not create the USB notification port")
      continuation.finish()
      return
    }
    self.port = port
    IONotificationPortSetDispatchQueue(port, queue)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
      var iterator: io_iterator_t = 0
      let result = IOServiceAddMatchingNotification(
        port, type, IOServiceMatching(kIOUSBHostDeviceClassName), usbChanged, refcon, &iterator)
      guard result == KERN_SUCCESS else {
        log.error("USB \(type, privacy: .public) notification failed: \(result, privacy: .public)")
        stop()
        continuation.finish()
        return
      }
      iterators.append(iterator)
      // The iterator must be drained to arm the notification.
      Self.drain(iterator)
    }
    continuation.yield()
  }

  func stop() {
    stopped = true
    for iterator in iterators {
      IOObjectRelease(iterator)
    }
    iterators = []
    if let port {
      IONotificationPortDestroy(port)
      self.port = nil
    }
  }

  fileprivate func changed(_ iterator: io_iterator_t) {
    Self.drain(iterator)
    continuation.yield()
  }

  private static func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
      IOObjectRelease(service)
    }
  }
}

/// Runs on the monitor's queue, which is its executor. The monitor stays alive while the port
/// exists: the stream's termination handler holds it until `stop()` destroys the port.
private func usbChanged(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
  guard let refcon else { return }
  Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue()
    .assumeIsolated { $0.changed(iterator) }
}
