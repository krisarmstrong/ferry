import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Finder learns of changes made on the device only when the agent lists the folder again.
@Suite(.timeLimit(.minutes(1)))
struct AgentRefreshTests {
  /// Lists `folder` of the device's domain through the service.
  func list(_ harness: AgentHarness, _ device: FakeDevice, _ folder: ItemID = .root)
    async throws -> [ProviderEntry]
  {
    guard
      case .entries(let entries) = await harness.service.handle(
        .list(domain: domainID(device), folder: folder), file: nil)
    else { throw TransportError.io("listing failed") }
    return entries
  }

  func changes(_ harness: AgentHarness, _ device: FakeDevice, since anchor: Data?)
    async throws -> ChangeLog.Since
  {
    guard
      case .changes(let next, let updated, let deleted, false) = await harness.service.handle(
        .changes(domain: domainID(device), since: anchor), file: nil)
    else { throw TransportError.io("no changes") }
    return ChangeLog.Since(anchor: next, updated: updated, deleted: deleted, expired: false)
  }

  @Test func refreshRecordsDeviceSideChangesInEveryKnownFolder() async throws {
    let device = await makeDevice("A")
    let storage = storageID(device)
    try await device.seed(path("/Download/old.txt"), in: storage, contents: Data("a".utf8))
    try await device.seed(path("/gone.txt"), in: storage, contents: Data("a".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let top = try await list(harness, device)
    let download = try #require(top.first { $0.item.path.name == "Download" })
    let gone = try #require(top.first { $0.item.path.name == "gone.txt" })
    _ = try await list(harness, device, download.id)
    let anchor = try await changes(harness, device, since: nil).anchor
    let signals = await harness.manager.calls.count

    try await device.seed(path("/Download/new.txt"), in: storage, contents: Data("b".utf8))
    try await device.delete(path("/gone.txt"), in: storage)
    #expect(await harness.service.handle(.refresh(device.info.id), file: nil) == .done)

    let since = try await changes(harness, device, since: anchor)
    #expect(since.updated.map(\.item.path) == [try path("/Download/new.txt")])
    #expect(since.deleted == [gone.id])
    #expect(await harness.manager.calls.dropFirst(signals) == [.signal(domainID(device))])
  }

  @Test func refreshWithNoChangeDoesNotSignal() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    _ = try await list(harness, device)
    let calls = await harness.manager.calls

    #expect(await harness.service.handle(.refresh(device.info.id), file: nil) == .done)
    #expect(await harness.manager.calls == calls)
  }

  /// A replugged device may have changed while it was away; its known folders are listed again
  /// before the domain is signalled.
  @Test func reconnectRefreshesKnownFolders() async throws {
    let device = await makeDevice("A")
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    _ = try await list(harness, device)
    let anchor = try await changes(harness, device, since: nil).anchor
    await harness.transport.detach(device.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)

    let replugged = await makeDevice("A")
    try await replugged.seed(path("/back.txt"), in: storageID(replugged), contents: Data("b".utf8))
    await harness.transport.attach(replugged)
    harness.tick()
    _ = await harness.manager.waitForCalls(4)

    let since = try await changes(harness, device, since: anchor)
    #expect(since.updated.map(\.item.path) == [try path("/back.txt")])
  }

  /// Refresh lists only what Finder has listed, not every folder a listing showed: otherwise
  /// each refresh would walk one level deeper, until a reconnect listed the whole device.
  @Test func refreshNeverListsFoldersFinderHasNotOpened() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/A/B/c.txt"), in: storageID(device), contents: Data("c".utf8))
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    _ = try await list(harness, device)
    let anchor = try await changes(harness, device, since: nil).anchor

    for _ in 0..<2 {
      #expect(await harness.service.handle(.refresh(device.info.id), file: nil) == .done)
    }

    #expect(try await changes(harness, device, since: anchor).updated.isEmpty)
  }
}
