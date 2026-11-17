import DeviceKit
import Testing

@testable import MTPTransport

struct DeviceProberTests {
  /// Records how many opens are in flight at once.
  actor OpenTracker {
    private(set) var peak = 0
    private var active = 0

    func enter() {
      active += 1
      peak = max(peak, active)
    }

    func leave() {
      active -= 1
    }
  }

  @Test func concurrentProbesNeverOverlap() async throws {
    let tracker = OpenTracker()
    let prober = DeviceProber<Int, Int>(
      label: "test-probe", detect: { [1, 2] },
      open: { raw in
        await tracker.enter()
        for _ in 0..<20 { await Task.yield() }
        await tracker.leave()
        return raw
      })

    async let first = prober.probe()
    async let second = prober.probe()
    let probes = try await [first, second]

    #expect(probes.map(\.opened) == [[1, 2], [1, 2]])
    #expect(await tracker.peak == 1)
  }

  @Test func deviceThatCannotBeOpenedMarksTheProbeBusy() async throws {
    let prober = DeviceProber<Int, Int>(
      label: "test-probe", detect: { [1, 2] },
      open: { raw throws(TransportError) in
        guard raw == 1 else { throw .deviceBusy }
        return raw
      })

    let probe = try await prober.probe()
    #expect(probe.opened == [1])
    #expect(probe.busy)
  }

  @Test func detectionFailureIsThrown() async throws {
    let prober = DeviceProber<Int, Int>(
      label: "test-probe", detect: { () throws(TransportError) in throw .io("usb") },
      open: { $0 })

    await #expect(throws: TransportError.io("usb")) {
      _ = try await prober.probe()
    }
  }
}
