import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// One unit served over MTP, with ADB about to turn up: both fakes hold the same files.
private struct Switching {
  let harness: AgentHarness
  let mtpDevice: FakeDevice
  let adbDevice: FakeDevice
  let domain: String
  let storage: StorageID

  init() async throws {
    mtpDevice = viaMTP("S1")
    adbDevice = viaADB("S1")
    storage = neutralStorage("S1").id
    for device in [mtpDevice, adbDevice] {
      try await device.seed(try path("/Docs/a.txt"), in: storage, contents: Data("a".utf8))
    }
    harness = try AgentHarness(
      devices: [mtpDevice], adb: FakeTransport(devices: [], method: .usbADB))
    domain = DomainNaming.identifier(for: storage)
    _ = await harness.manager.waitForCalls(1)
  }

  var adb: FakeTransport { harness.adb! }

  func list(_ folder: ItemID) async -> AgentResponse {
    await harness.service.handle(.list(domain: domain, folder: folder), file: nil)
  }

  /// Plugs ADB in and returns once the hub serves the device over it.
  func switchToADB() async {
    await adb.attach(adbDevice)
    harness.tick()
    await waitForMethod(.usbADB)
  }

  /// The item's identifier once the domain is connected again: a device that left one route and
  /// came back on another is detached and attached, which disconnects its domain meanwhile.
  func idOnceConnected(_ string: String) async throws -> ItemID? {
    let item = try path(string)
    while !Task.isCancelled {
      do throws(TransportError) {
        return try await harness.controller.items(of: domain).id(for: item)
      } catch .deviceDisconnected {
        await Task.yield()
      }
    }
    return nil
  }

  func waitForMethod(_ method: ConnectionMethod) async {
    while await currentMethod != method, !Task.isCancelled {
      await Task.yield()
    }
  }

  var currentMethod: ConnectionMethod? {
    get async {
      await harness.hub.devices().first { $0.id == mtpDevice.info.id }?.method
    }
  }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentMethodSwitchTests {
  /// The unit is on the cable (MTP) and connected over the network too: USB serves it. Unplugged,
  /// the network takes over the same Finder location; plugged back in, USB serves it again.
  @Test func theNetworkServesOnlyWhileNoUSBRouteDoes() async throws {
    let setup = try await Switching()
    defer { setup.harness.finish() }
    let id = setup.mtpDevice.info.id
    let file = try await setup.harness.id(try path("/Docs/a.txt"), in: setup.domain)
    await setup.adb.setMethod(.wifiADB, for: id)
    await setup.adb.attach(setup.adbDevice)
    setup.harness.tick()
    _ = await setup.harness.barrier(after: 1)
    #expect(await setup.harness.hub.devices().first { $0.id == id }?.method == .usbFileTransfer)
    #expect(await setup.adb.openCount(of: id) == 0)

    await setup.harness.transport.detach(id)
    setup.harness.tick()
    await setup.waitForMethod(.wifiADB)
    #expect(try await setup.idOnceConnected("/Docs/a.txt") == file)

    let back = viaMTP("S1")
    try await back.seed(try path("/Docs/a.txt"), in: setup.storage, contents: Data("a".utf8))
    await setup.harness.transport.attach(back)
    setup.harness.tick()
    await setup.waitForMethod(.usbFileTransfer)
    #expect(try await setup.idOnceConnected("/Docs/a.txt") == file)
    let adds = await setup.harness.manager.calls.filter { call in
      if case .add(let spec) = call { return spec.identifier == setup.domain }
      return false
    }
    #expect(adds.count == 1)
  }

  /// The Finder location and every item's identity stay put across MTP → ADB → MTP: a swap is a
  /// session replacement, not a new domain.
  @Test func identitiesSurviveTheSwitch() async throws {
    let setup = try await Switching()
    defer { setup.harness.finish() }
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let before = await setup.list(docs)
    let file = try await setup.harness.id(try path("/Docs/a.txt"), in: setup.domain)

    await setup.switchToADB()
    // Same items under the same identifiers; dates are each fake's own.
    #expect(await setup.list(docs).identities == before.identities)
    #expect(!before.identities.isEmpty)
    #expect(try await setup.harness.id(try path("/Docs/a.txt"), in: setup.domain) == file)
    let made = await setup.harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "New", isFolder: true), file: nil)
    #expect(made.isEntry)
    #expect(await setup.adbDevice.allPaths(in: setup.storage).contains(try path("/Docs/New")))
    #expect(await !setup.mtpDevice.allPaths(in: setup.storage).contains(try path("/Docs/New")))

    await setup.adb.detach(setup.adbDevice.info.id)
    setup.harness.tick()
    await setup.waitForMethod(.usbFileTransfer)
    #expect(try await setup.harness.id(try path("/Docs/a.txt"), in: setup.domain) == file)

    let calls = await setup.harness.manager.calls
    #expect(calls.filter { if case .add = $0 { true } else { false } }.count == 1)
    #expect(!calls.contains { if case .remove = $0 { true } else { false } })
  }

  /// Review Focus 1: a copy running when ADB turns up finishes on MTP, and the swap follows it.
  @Test func aCopyInFlightFinishesOnTheOldSession() async throws {
    let setup = try await Switching()
    defer { setup.harness.finish() }
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let (adb, adbDevice, harness) = (setup.adb, setup.adbDevice, setup.harness)
    await setup.mtpDevice.onNextUpload {
      await adb.attach(adbDevice)
      harness.tick()
      while await !harness.hub.isSwapping(adbDevice.info.id), !Task.isCancelled {
        await Task.yield()
      }
    }

    let reply = await harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "b.txt", isFolder: false),
      file: try harness.readable("b.txt", "bee"))

    #expect(reply.isEntry)
    #expect(
      await setup.mtpDevice.contents(of: try path("/Docs/b.txt"), in: setup.storage)
        == Data("bee".utf8))
    await setup.waitForMethod(.usbADB)
  }

  /// Review Focus 1: the cable is pulled mid-copy while the network carries on. The copy fails
  /// as a disconnection, nothing appears under its name, and the device carries on over ADB.
  @Test func aCopyCutOffBySwitchingLeavesNothingVisible() async throws {
    let setup = try await Switching()
    defer { setup.harness.finish() }
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let (mtp, mtpDevice, adb, adbDevice, harness) = (
      setup.harness.transport, setup.mtpDevice, setup.adb, setup.adbDevice, setup.harness
    )
    await mtpDevice.onNextUpload {
      await mtp.detach(mtpDevice.info.id)
      await adb.setMethod(.wifiADB, for: adbDevice.info.id)
      await adb.attach(adbDevice)
    }

    let reply = await harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "b.txt", isFolder: false),
      file: try harness.readable("b.txt", "bee"))
    #expect(reply == .failure(.deviceDisconnected))

    harness.tick()
    await setup.waitForMethod(.wifiADB)
    // The device left over MTP and came back over the network: its domain reconnects.
    var listing = await setup.list(docs)
    while listing == .failure(.deviceDisconnected), !Task.isCancelled {
      await Task.yield()
      listing = await setup.list(docs)
    }
    guard case .entries(let entries) = listing else {
      Issue.record("expected entries, got \(listing)")
      return
    }
    #expect(entries.compactMap(\.item.path.name) == ["a.txt"])
  }
}

extension AgentResponse {
  fileprivate var identities: [String] {
    guard case .entries(let entries) = self else { return [] }
    return entries.map { "\($0.id) \($0.item.path)" }
  }
}
