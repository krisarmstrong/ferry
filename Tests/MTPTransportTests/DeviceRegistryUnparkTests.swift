import DeviceKit
import Testing

@testable import MTPTransport

/// The user's Check Again (`unpark`) takes its turn with scans, so a scan already under way cannot
/// undo it.
extension DeviceRegistryTests {
  /// Holds the first open until released; later opens go straight through.
  actor OpenHold {
    private var armed = true
    private var held: CheckedContinuation<Void, Never>?
    private var holding: [CheckedContinuation<Void, Never>] = []

    func open() async {
      guard armed else { return }
      armed = false
      for waiter in holding { waiter.resume() }
      holding = []
      await withCheckedContinuation { held = $0 }
    }

    /// Returns once the held open has started.
    func started() async {
      guard armed else { return }
      await withCheckedContinuation { holding.append($0) }
    }

    func release() {
      held?.resume()
      held = nil
    }
  }

  actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
  }

  /// A scan is opening the device when the user asks to check it again, and the open fails
  /// (another app still held it when the scan tried). The check came after that try, so the
  /// next scan tries again rather than reporting the device busy from the record.
  @Test func checkAgainDuringAFailingOpenIsKept() async throws {
    let bus = Bus([1])
    await bus.log.setBusy([1])
    let hold = OpenHold()
    let registry = makeRegistry(bus, opening: { await hold.open() })
    let scanning = Task { try await registry.scan() }
    await hold.started()

    let unparked = Flag()
    let unparking = Task {
      await registry.unpark(Self.busyInfo(1).id)
      await unparked.set()
    }
    // The check has arrived: it either ran already or waits for the scan's turn to end.
    while await !unparked.isSet, await registry.queued == 0 { await Task.yield() }
    await hold.release()

    #expect(try await scanning.value == DeviceScan(devices: [], busy: [Self.busyInfo(1)]))
    await unparking.value
    await bus.log.setBusy([])
    #expect(try await registry.scan() == DeviceScan(devices: [Self.info(1)]))
    #expect(await bus.log.opens == [1: 1])
  }
}
