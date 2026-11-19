import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

@Suite(.timeLimit(.minutes(1)))
struct DomainControllerLeftoverTests {
  /// A unit unplugged from MTP and back over ADB is reconnected, which lists its folders and
  /// signals once. Its method from before the detach is forgotten, so no method-change resync
  /// signals a second time.
  @Test func aDetachForgetsTheMethodSoAReturnIsNoMethodChange() async throws {
    let mtpDevice = viaMTP("S1")
    let adbDevice = viaADB("S1")
    let adb = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [mtpDevice], adb: adb)
    defer { harness.finish() }
    let domain = DomainNaming.identifier(for: neutralStorage("S1").id)
    _ = await harness.manager.waitForCalls(1)

    await harness.transport.detach(mtpDevice.info.id)
    harness.tick()
    _ = await harness.manager.waitForCalls(2)
    await adb.attach(adbDevice)
    harness.tick()
    _ = await harness.barrier(after: 3)
    // The barrier's domain is added after every call the unit's return made.
    var calls = await harness.manager.calls
    while !calls.contains(.add(AgentHarness.barrierSpec)), !Task.isCancelled {
      await Task.yield()
      calls = await harness.manager.calls
    }

    #expect(calls.contains(.reconnect(domain)))
    #expect(calls.filter { $0 == .signal(domain) }.count == 1)
  }

  /// Remove Ferry leaves nothing in the item store, including the card alias file that builds
  /// before 2026-11-18 wrote there.
  @Test func removeAllDeletesTheStaleAliasFile() async throws {
    let harness = try AgentHarness()
    defer { harness.finish() }
    try FileManager.default.createDirectory(at: harness.store, withIntermediateDirectories: true)
    let aliases = harness.store.appending(path: "storage-aliases.plist")
    try Data("stale".utf8).write(to: aliases)

    _ = try await harness.controller.removeAll()

    #expect(!FileManager.default.fileExists(atPath: aliases.path))
  }
}
