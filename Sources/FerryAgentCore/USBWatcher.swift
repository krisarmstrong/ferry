import Dispatch
import IOKit
import IOKit.usb
import MTPTransport
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "USBWatcher")

/// Ticks whenever a device Ferry may use attaches or detaches, for `DeviceHub`'s `arrivals`.
///
/// Every other device (an iPhone, a keyboard, a hub) is ignored, so it never makes the hub scan.
/// A device's interfaces register after the device itself, so the watcher also follows
/// interfaces: an MTP interface turning up is what makes most devices candidates. A detached
/// device's interfaces are already gone, so departures tick for the devices remembered as
/// candidates when they arrived.
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

/// One IOKit notification the monitor asks for.
private struct Subscription {
  let type: String
  let className: String
  let callback: IOServiceMatchingCallback

  init(_ type: String, _ className: String, _ callback: IOServiceMatchingCallback) {
    self.type = type
    self.className = className
    self.callback = callback
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
  /// Registry IDs of the attached devices that are candidates.
  private var candidates: Set<UInt64> = []

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
    let subscriptions = [
      Subscription(kIOFirstMatchNotification, kIOUSBHostDeviceClassName, usbArrived),
      Subscription(kIOFirstMatchNotification, kIOUSBHostInterfaceClassName, usbArrived),
      Subscription(kIOTerminatedNotification, kIOUSBHostDeviceClassName, usbLeft),
    ]
    for subscription in subscriptions {
      var iterator: io_iterator_t = 0
      let result = IOServiceAddMatchingNotification(
        port, subscription.type, IOServiceMatching(subscription.className),
        subscription.callback, refcon, &iterator)
      guard result == KERN_SUCCESS else {
        log.error(
          "USB \(subscription.type, privacy: .public) notification failed: \(result, privacy: .public)"
        )
        stop()
        continuation.finish()
        return
      }
      iterators.append(iterator)
      // The iterator must be drained to arm the notification; what is already attached is
      // recorded but does not tick, as the hub scans once at start.
      if subscription.type == kIOFirstMatchNotification {
        _ = arrived(iterator)
      } else {
        _ = left(iterator)
      }
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

  fileprivate func arrivedNotification(_ iterator: io_iterator_t) {
    if arrived(iterator) { continuation.yield() }
  }

  fileprivate func leftNotification(_ iterator: io_iterator_t) {
    if left(iterator) { continuation.yield() }
  }

  /// Drains devices or interfaces that arrived. True if any belongs to a candidate device.
  private func arrived(_ iterator: io_iterator_t) -> Bool {
    var relevant = false
    while case let service = IOIteratorNext(iterator), service != 0 {
      if let device = USBRegistry.candidateDevice(service) {
        candidates.insert(device)
        relevant = true
      }
      IOObjectRelease(service)
    }
    return relevant
  }

  /// Drains devices that left. True if any was a candidate.
  private func left(_ iterator: io_iterator_t) -> Bool {
    var relevant = false
    while case let service = IOIteratorNext(iterator), service != 0 {
      if let id = USBRegistry.registryID(of: service), candidates.remove(id) != nil {
        relevant = true
      }
      IOObjectRelease(service)
    }
    return relevant
  }
}

/// These run on the monitor's queue, which is its executor. The monitor stays alive while the
/// port exists: the stream's termination handler holds it until `stop()` destroys the port.
private func usbArrived(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
  guard let refcon else { return }
  Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue()
    .assumeIsolated { $0.arrivedNotification(iterator) }
}

private func usbLeft(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
  guard let refcon else { return }
  Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue()
    .assumeIsolated { $0.leftNotification(iterator) }
}
