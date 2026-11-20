import DeviceKit
import Testing

@testable import MTPTransport

/// A device outside libmtp's table may still be matching its drivers when it first appears, so
/// whether a driver owns its interface is not known yet: it is opened only once it has been
/// attached for a second.
struct DeviceRegistrySettleTests {
  @Test func anUnlistedDeviceIsOpenedOnlyOnceItHasSettled() async throws {
    let bus = DeviceRegistryTests.Bus([1])
    let log = bus.log
    let registry = DeviceRegistry<Int, DeviceRegistryTests.Handle>(
      label: "test-registry",
      driver: .init(
        attached: { bus.devices },
        candidacy: { _ in .probe },
        resolve: { Int($0.address) },
        open: { raw, _ throws(TransportError) in
          let handle = try await log.open(raw)
          return (handle, await log.info(handle))
        },
        close: { await log.close($0) },
        now: { bus.now }))

    let first = try await registry.scan()
    #expect(first.devices.isEmpty)
    #expect(first.rescanAfter == .seconds(1))
    #expect(await log.opens.isEmpty)

    bus.advance(by: .milliseconds(400))
    #expect(try await registry.scan().rescanAfter == .milliseconds(600))
    #expect(await log.opens.isEmpty)

    bus.advance(by: .milliseconds(600))
    #expect(try await registry.scan().devices == [DeviceRegistryTests.info(1)])
    #expect(await log.opens == [1: 1])
  }
}
