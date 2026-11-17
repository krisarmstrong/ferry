import DeviceKit
import Dispatch
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DeviceProber")

/// Detects attached devices and opens each one.
///
/// Detection blocks on USB, so it runs on this actor's own queue rather than the cooperative
/// pool. A probe suspends while each device opens on that device's own queue, and an actor
/// takes other calls across a suspension, so probes are chained: each starts once the previous
/// one has finished, and two probes never race each other for the same interface.
actor DeviceProber<Raw: Sendable, Device: Sendable> {
  struct Probe: Sendable {
    var opened: [Device] = []
    /// At least one detected device could not be opened.
    var busy = false
  }

  typealias Detect = @Sendable () throws(TransportError) -> [Raw]
  typealias Open = @Sendable (Raw) async throws(TransportError) -> Device

  private let queue: DispatchSerialQueue
  private let detect: Detect
  private let open: Open
  /// The probe most recently started; the next one waits for it.
  private var last: Task<Void, Never>?

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(label: String, detect: @escaping Detect, open: @escaping Open) {
    self.queue = DispatchSerialQueue(label: label)
    self.detect = detect
    self.open = open
  }

  func probe() async throws(TransportError) -> Probe {
    let previous = last
    let current = Task {
      _ = await previous?.value
      return await run()
    }
    // Only completion is kept, so a finished probe's devices are not held here.
    last = Task { _ = await current.value }
    return try await current.value.get()
  }

  private func run() async -> Result<Probe, TransportError> {
    let raws: [Raw]
    do {
      raws = try detect()
    } catch {
      return .failure(error)
    }
    var probe = Probe()
    for raw in raws {
      do {
        probe.opened.append(try await open(raw))
      } catch {
        log.notice("could not open a device: \(String(describing: error), privacy: .public)")
        probe.busy = true
      }
    }
    return .success(probe)
  }
}
