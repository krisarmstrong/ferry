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

  /// Served over MTP, or, given `over`, by ADB alone over that route (MTP not attached).
  init(over route: ConnectionMethod? = nil) async throws {
    mtpDevice = viaMTP("S1")
    adbDevice = viaADB("S1")
    storage = neutralStorage("S1").id
    for device in [mtpDevice, adbDevice] {
      try await device.seed(try path("/Docs/a.txt"), in: storage, contents: Data("a".utf8))
    }
    let adb = FakeTransport(devices: route == nil ? [] : [adbDevice], method: .usbADB)
    if let route { await adb.setMethod(route, for: adbDevice.info.id) }
    harness = try AgentHarness(devices: route == nil ? [mtpDevice] : [], adb: adb)
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

  /// Review Focus 1: ADB turns up while a copy runs over MTP. The swap waits for the copy: ADB
  /// is not opened until it has finished on MTP, and the file is whole on the device that took
  /// it.
  @Test func aCopyInFlightFinishesBeforeADBIsOpened() async throws {
    let setup = try await Switching()
    defer { setup.harness.finish() }
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let (adb, adbDevice, hub) = (setup.adb, setup.adbDevice, setup.harness.hub)
    let opensDuringCopy = Counter()
    let tick = setup.harness.tick
    await setup.mtpDevice.onNextUpload {
      await adb.attach(adbDevice)
      tick()
      // The swap has begun and is waiting for this copy's lease.
      while await hub.waitingForRequests == 0, !Task.isCancelled { await Task.yield() }
      await opensDuringCopy.set(await adb.openCount(of: adbDevice.info.id))
    }

    let reply = await setup.harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "b.txt", isFolder: false),
      file: try setup.harness.readable("b.txt", "bee"))

    #expect(reply.isEntry)
    #expect(await opensDuringCopy.value == 0)
    #expect(
      await setup.mtpDevice.contents(of: try path("/Docs/b.txt"), in: setup.storage)
        == Data("bee".utf8))
    #expect(
      await !setup.mtpDevice.allPaths(in: setup.storage).contains {
        SafeWriter.isPartial($0.name ?? "")
      })
    await setup.waitForMethod(.usbADB)
  }

  /// Review Focus 1: the cable goes in while a copy runs over the network. ADB holds one session
  /// per device, so the swap closes it, but only once the copy has finished; the file is whole on
  /// the device that took it, with no partial left.
  @Test func aNetworkCopyFinishesBeforeUSBTakesOver() async throws {
    let setup = try await Switching(over: .wifiADB)
    defer { setup.harness.finish() }
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let (mtp, mtpDevice, adbDevice, hub) = (
      setup.harness.transport, setup.mtpDevice, setup.adbDevice, setup.harness.hub
    )
    let closesDuringCopy = Counter()
    let tick = setup.harness.tick
    await adbDevice.onNextUpload {
      await mtp.attach(mtpDevice)
      tick()
      while await hub.waitingForRequests == 0, !Task.isCancelled { await Task.yield() }
      await closesDuringCopy.set(await adbDevice.closeCount)
    }

    let reply = await setup.harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "b.txt", isFolder: false),
      file: try setup.harness.readable("b.txt", "bee"))

    #expect(reply.isEntry)
    #expect(await closesDuringCopy.value == 0)
    #expect(
      await adbDevice.contents(of: try path("/Docs/b.txt"), in: setup.storage) == Data("bee".utf8))
    #expect(
      await !adbDevice.allPaths(in: setup.storage).contains { SafeWriter.isPartial($0.name ?? "") })
    await setup.waitForMethod(.usbFileTransfer)
    #expect(await adbDevice.closeCount == 1)
  }

  /// Review Focus 1: USB debugging is revoked while a copy runs over ADB, and MTP is there. The
  /// ADB session is closed only after the copy finished on it.
  @Test func anADBCopyFinishesBeforeMTPTakesOver() async throws {
    let setup = try await Switching(over: .usbADB)
    defer { setup.harness.finish() }
    await setup.harness.transport.attach(setup.mtpDevice)
    setup.harness.tick()
    _ = await setup.harness.barrier(after: 1)
    #expect(await setup.currentMethod == .usbADB)
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let (adb, adbDevice, hub) = (setup.adb, setup.adbDevice, setup.harness.hub)
    let closesDuringCopy = Counter()
    let tick = setup.harness.tick
    await adbDevice.onNextUpload {
      await adb.withdraw(adbDevice.info.id)
      tick()
      while await hub.waitingForRequests == 0, !Task.isCancelled { await Task.yield() }
      await closesDuringCopy.set(await adbDevice.closeCount)
    }

    let reply = await setup.harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "b.txt", isFolder: false),
      file: try setup.harness.readable("b.txt", "bee"))

    #expect(reply.isEntry)
    #expect(await closesDuringCopy.value == 0)
    #expect(
      await adbDevice.contents(of: try path("/Docs/b.txt"), in: setup.storage) == Data("bee".utf8))
    await setup.waitForMethod(.usbFileTransfer)
    #expect(await adbDevice.closeCount == 1)
  }

  /// Review Focus 1: the cable is pulled mid-copy. The copy fails as a disconnection, and the
  /// device that ran it has nothing under the name and no partial.
  @Test func aCopyCutOffLeavesNothingOnTheDeviceThatRanIt() async throws {
    let setup = try await Switching()
    defer { setup.harness.finish() }
    let docs = try await setup.harness.id(try path("/Docs"), in: setup.domain)
    let (mtp, mtpDevice) = (setup.harness.transport, setup.mtpDevice)
    await mtpDevice.onNextUpload {
      await mtp.detach(mtpDevice.info.id)
    }

    let reply = await setup.harness.service.handle(
      .create(domain: setup.domain, parent: docs, name: "b.txt", isFolder: false),
      file: try setup.harness.readable("b.txt", "bee"))

    #expect(reply == .failure(.deviceDisconnected))
    let left = await mtpDevice.allPaths(in: setup.storage).compactMap(\.name)
    #expect(!left.contains("b.txt"))
    #expect(!left.contains(where: SafeWriter.isPartial))
  }
}

/// A value a test's hook records for the test to check afterwards.
actor Counter {
  private(set) var value = -1
  func set(_ value: Int) { self.value = value }
}

extension AgentResponse {
  fileprivate var identities: [String] {
    guard case .entries(let entries) = self else { return [] }
    return entries.map { "\($0.id) \($0.item.path)" }
  }
}
