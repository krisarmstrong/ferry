import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A device's Finder location shows only while the device is served. A device that is away has
/// its domain hidden, never removed, so its files and unsent changes stay for when it is back.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerHiddenTests {
  @Test func unplugHidesTheLocationAndReplugShowsIt() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    #expect(await harness.manager.visible == [domain])

    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.barrier(after: 2)
    #expect(await harness.manager.hidden == [domain])
    #expect(await harness.manager.registered.contains(domain))
    #expect(!(await harness.manager.calls.contains(.remove(domain))))

    await harness.transport.attach(await makeDevice("A"))
    harness.tick()
    _ = await harness.manager.waitForCalls(5)
    let calls = await harness.manager.calls
    #expect(calls.contains(.reconnect(domain)))
    #expect(await harness.manager.visible.contains(domain))
    #expect(await harness.manager.hidden.isEmpty)
    #expect(await harness.manager.shownButDisconnected.isEmpty)
  }

  /// At start, every domain from before is hidden until its device is served again; one whose
  /// device is ready shows again.
  @Test func startHidesDomainsOfDevicesNotConnected() async throws {
    let device = await makeDevice("A")
    let gone = DomainNaming.identifier(
      for: StorageID(device: DeviceID(serial: "GONE"), key: internalKey))
    let harness = try AgentHarness(devices: [device], existing: [domainID(device), gone])
    defer { harness.finish() }

    _ = await harness.barrier(after: 4)
    #expect(await harness.manager.hidden == [gone])
    #expect(
      await harness.manager.visible == [domainID(device), AgentHarness.barrierSpec.identifier])
    #expect(await harness.manager.registered.contains(gone))
    #expect(await harness.manager.shownButDisconnected.isEmpty)
  }

  /// A show that fails is tried again on the next change, so a served device's location never
  /// stays hidden.
  @Test func aFailedShowIsRetried() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.barrier(after: 2)
    #expect(await harness.manager.hidden == [domain])

    // Both tries during the replug fail: the reconnect's own, and the one that ends it.
    await harness.manager.failVisibility(2)
    await harness.transport.attach(await makeDevice("A"))
    harness.tick()
    _ = await harness.manager.waitForCalls(5)
    // Any later change reconciles again: another device arriving is one.
    await harness.transport.attach(await makeDevice("B", model: "Other"))
    harness.tick()
    _ = await harness.manager.waitForCalls(6)
    #expect(await harness.manager.waitUntilHidden([]).isEmpty)
    #expect(await harness.manager.visible.contains(domain))
  }

  /// A hide that fails is tried again on the next change, so an unplugged device never stays in
  /// Finder.
  @Test func aFailedHideIsRetried() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    // Both tries during the unplug fail: the disconnect's own, and the one that ends it.
    await harness.manager.failVisibility(2)
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)
    // The barrier's device arriving reconciles again.
    _ = await harness.barrier(after: 2)
    #expect(await harness.manager.waitUntilHidden([domain]) == [domain])
  }

  /// A request on a domain whose device is away fails at once with `.deviceDisconnected`, which
  /// the extension shows with the domain's "Connect the device" reason, without asking the
  /// device or waiting for it. The suite's time limit is the bound on "at once".
  @Test func aRequestOnAHiddenDomainFailsAtOnce() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.barrier(after: 2)

    #expect(
      await harness.service.handle(.list(domain: domainID(device), folder: .root), file: nil)
        == .failure(.deviceDisconnected))
  }

  /// An ejected device leaves Finder (its domain is removed, keeping unsent changes) and Mount
  /// shows it again.
  @Test func ejectLeavesFinderAndMountShows() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)

    _ = await harness.service.handle(.eject(device.info.id), file: nil)
    #expect(!(await harness.manager.visible.contains(domain)))

    _ = await harness.service.handle(.recheck(device.info.id), file: nil)
    _ = await harness.manager.waitForCalls(3)
    #expect(await harness.manager.visible == [domain])
  }

  /// Remove Ferry removes hidden domains too.
  @Test func removeFerryRemovesHiddenDomains() async throws {
    let gone = DomainNaming.identifier(
      for: StorageID(device: DeviceID(serial: "GONE"), key: internalKey))
    let harness = try AgentHarness(existing: [gone])
    defer { harness.finish() }
    _ = await harness.barrier(after: 1)
    #expect(await harness.manager.hidden == [gone])

    #expect(await harness.service.handle(.removeAllDomains, file: nil) == .removed(preserved: []))
    #expect(await harness.manager.registered.isEmpty)
  }
}
