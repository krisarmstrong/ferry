import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Every wait here is on a call the controller should make, so a regression hangs; the limit
/// fails it.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerTests {
  @Test func namesDisambiguateSameModelAndSDCard() async throws {
    let first = await makeDevice(
      "SER0000AAAA", model: "LinkRunner 10G", keys: [internalKey, cardKey])
    let second = await makeDevice("SER0000BBBB", model: "LinkRunner 10G")
    let other = await makeDevice("SER0000CCCC", model: "Phone")
    let locked = await makeDevice("SER0000DDDD", model: "Phone")
    let firstReady = try await AttachedDevice(info: first.info, state: .ready(first.storages()))
    let secondReady = try await AttachedDevice(info: second.info, state: .ready(second.storages()))
    let otherReady = try await AttachedDevice(info: other.info, state: .ready(other.storages()))
    let lockedState = AttachedDevice(info: locked.info, state: .notSharingFiles)

    let specs = DomainNaming.specs(for: [firstReady, secondReady, otherReady, lockedState])

    try #require(specs.count == 4)
    #expect(
      specs[0] == DomainSpec(identifier: domainID(first), displayName: "LinkRunner 10G (AAAA)"))
    #expect(specs[1].identifier == domainID(first, cardKey))
    #expect(specs[1].displayName == "LinkRunner 10G (AAAA) – SD card")
    #expect(
      specs[2] == DomainSpec(identifier: domainID(second), displayName: "LinkRunner 10G (BBBB)"))
    // Two Phones are attached, but the locked one gets no domain.
    #expect(specs[3] == DomainSpec(identifier: domainID(other), displayName: "Phone (CCCC)"))
    #expect(
      DomainNaming.specs(for: [otherReady])
        == [DomainSpec(identifier: domainID(other), displayName: "Phone")])
  }

  @Test func readyDeviceAddsOneDomainPerStorage() async throws {
    let device = await makeDevice("A", keys: [internalKey, cardKey])
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }

    let primary = DomainSpec(identifier: domainID(device), displayName: "Phone")
    let card = DomainSpec(identifier: domainID(device, cardKey), displayName: "Phone – SD card")
    #expect(await harness.manager.waitForCalls(2) == [.add(primary), .add(card)])
    #expect(
      await harness.service.handle(.list(domain: domainID(device), folder: .root)) == .items([]))
    #expect(
      await harness.service.handle(.list(domain: domainID(device, cardKey), folder: .root))
        == .items([]))
  }

  @Test func lockedDeviceGetsNoDomainAndReportsState() async throws {
    let device = await makeDevice("LOCKED", locked: true)
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }

    #expect(await harness.barrier(after: 0) == [.add(AgentHarness.barrierSpec)])
    guard case .status(let devices, let enabled) = await harness.service.handle(.status) else {
      Issue.record("expected a status")
      return
    }
    #expect(devices.first { $0.id == device.info.id }?.state == .notSharingFiles)
    #expect(!enabled)
    #expect(
      await harness.service.handle(.list(domain: domainID(device), folder: .root))
        == .failure(.storageNotFound(domainID(device))))

    await harness.manager.setUserEnabled(true)
    guard case .status(_, true) = await harness.service.handle(.status) else {
      Issue.record("expected an enabled provider")
      return
    }
  }

  @Test func secondDeviceOfSameModelRenamesFirst() async throws {
    let first = await makeDevice("SER0000AAAA")
    let harness = try AgentHarness(devices: [first])
    defer { harness.finish() }
    let alone = DomainSpec(identifier: domainID(first), displayName: "Phone")
    #expect(await harness.manager.waitForCalls(1) == [.add(alone)])

    let second = await makeDevice("SER0000BBBB")
    await harness.transport.attach(second)
    harness.tick()

    let renamed = DomainSpec(identifier: domainID(first), displayName: "Phone (AAAA)")
    let added = DomainSpec(identifier: domainID(second), displayName: "Phone (BBBB)")
    #expect(await harness.manager.waitForCalls(3) == [.add(alone), .add(renamed), .add(added)])
  }

  @Test func busyDeviceGetsDomainOnlyOnceFreed() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness()
    defer { harness.finish() }
    await harness.transport.attach(device)
    await harness.transport.setHeldByAnotherApp(device.info.id, true)
    harness.tick()
    #expect(await harness.barrier(after: 0) == [.add(AgentHarness.barrierSpec)])

    await harness.transport.setHeldByAnotherApp(device.info.id, false)
    harness.tick()

    let added = DomainSpec(identifier: domainID(device), displayName: "Phone")
    #expect(await harness.manager.waitForCalls(2) == [.add(AgentHarness.barrierSpec), .add(added)])
  }

  @Test func unplugDisconnectsDomainAndFailsPending() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    await device.suspendNext(.list)
    let pending = Task { [service = harness.service] in
      await service.handle(.list(domain: domainID(device), folder: .root))
    }
    await device.waitUntilSuspended(.list)

    await harness.transport.detach(device.info.id)
    harness.tick()
    #expect(await harness.manager.waitForCalls(2).last == .disconnect(domainID(device)))
    await device.resume(.list)

    #expect(await pending.value == .failure(.deviceDisconnected))
    #expect(
      await harness.service.handle(.list(domain: domainID(device), folder: .root))
        == .failure(.deviceDisconnected))
  }

  @Test func replugReconnectsSameDomain() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)

    let replugged = await makeDevice("A")
    try await replugged.seed(path("/back.txt"), in: storageID(replugged), contents: Data("hi".utf8))
    await harness.transport.attach(replugged)
    harness.tick()

    let domain = domainID(device)
    let added = FakeDomainManager.Call.add(DomainSpec(identifier: domain, displayName: "Phone"))
    let barrier = FakeDomainManager.Call.add(AgentHarness.barrierSpec)
    #expect(
      await harness.barrier(after: 3) == [added, .disconnect(domain), .reconnect(domain), barrier])
    guard
      case .items(let items) = await harness.service.handle(
        .list(domain: domainID(device), folder: .root))
    else {
      Issue.record("expected a listing")
      return
    }
    #expect(items.map(\.path) == [try path("/back.txt")])
  }

  @Test func ejectRemovesOnlyThatDevice() async throws {
    let first = await makeDevice("A", model: "First")
    let second = await makeDevice("B", model: "Second")
    let harness = try AgentHarness(devices: [first, second])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(2)

    #expect(await harness.service.handle(.eject(first.info.id)) == .done)

    let firstAdded = FakeDomainManager.Call.add(
      DomainSpec(identifier: domainID(first), displayName: "First"))
    let secondAdded = FakeDomainManager.Call.add(
      DomainSpec(identifier: domainID(second), displayName: "Second"))
    let removed = FakeDomainManager.Call.remove(domainID(first))
    let barrier = FakeDomainManager.Call.add(AgentHarness.barrierSpec)
    #expect(await harness.barrier(after: 3) == [firstAdded, secondAdded, removed, barrier])
    #expect(await first.closeCount == 1)
    #expect(
      await harness.hub.devices().first { $0.id == first.info.id }?.state == .notSharingFiles)
    #expect(
      await harness.service.handle(.list(domain: domainID(first), folder: .root))
        == .failure(.storageNotFound(domainID(first))))
    #expect(
      await harness.service.handle(.list(domain: domainID(second), folder: .root)) == .items([]))
  }

  @Test func removeAllDomainsForgetsEveryDomain() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)

    #expect(await harness.service.handle(.removeAllDomains) == .done)

    #expect(await harness.manager.calls.last == .removeAll)
    #expect(
      await harness.service.handle(.list(domain: domainID(device), folder: .root))
        == .failure(.storageNotFound(domainID(device))))
  }
}
