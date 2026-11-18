import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// An SD card keeps one Finder location whichever method serves it. Android's MTP server sends
/// no volume ID, so MTP knows the card only by its description; once ADB has served the device,
/// the agent remembers which volume that description is.
@Suite(.timeLimit(.minutes(1)))
struct DomainControllerCardTests {
  static let id = DeviceID(serial: "S1")
  static let mtpCard = StorageID(device: id, key: "SD card|")
  static let adbCard = StorageID(device: id, key: StorageKey.volume("1234-ABCD"))
  static let photo = "/DCIM/p.jpg"

  static let cardA = (volume: "1234-ABCD", capacity: UInt64(1 << 30))
  static let cardB = (volume: "5678-EF01", capacity: UInt64(1 << 31))

  /// The unit over MTP with a card of `capacity` holding `file`; its MTP key is the card's
  /// description, the same for every card of the vendor.
  func mtp(capacity: UInt64 = cardA.capacity, file: String = photo) async throws -> FakeDevice {
    let device = FakeDevice(
      info: DeviceInfo(id: Self.id, manufacturer: "NetAlly", model: "LinkRunner-100G"),
      storages: [
        neutralStorage("S1"),
        StorageInfo(id: Self.mtpCard, description: "SD card", capacity: capacity, free: 1 << 29),
      ])
    try await device.seed(try path(file), in: Self.mtpCard, contents: Data("p".utf8))
    return device
  }

  /// The unit over ADB with the volume `volume` of `capacity` holding `file`.
  func adb(
    volume: String = cardA.volume, capacity: UInt64 = cardA.capacity, file: String = photo
  ) async throws -> FakeDevice {
    let card = StorageID(device: Self.id, key: StorageKey.volume(volume))
    let device = FakeDevice(
      info: DeviceInfo(id: Self.id, manufacturer: "", model: "LinkRunner 100G"),
      storages: [
        neutralStorage("S1"),
        StorageInfo(
          id: card, description: "Removable storage", capacity: capacity, free: 1 << 29),
      ])
    try await device.seed(try path(file), in: card, contents: Data("p".utf8))
    return device
  }

  static let oldCardDomain = DomainNaming.identifier(for: mtpCard)
  static let cardDomain = DomainNaming.identifier(for: adbCard)

  func until(_ harness: AgentHarness, _ condition: ([FakeDomainManager.Call]) -> Bool) async {
    while await !condition(harness.manager.calls), !Task.isCancelled { await Task.yield() }
  }

  func served(_ harness: AgentHarness, by method: ConnectionMethod) async {
    while await harness.hub.devices().first?.method != method, !Task.isCancelled {
      await Task.yield()
    }
  }

  func cardID(_ harness: AgentHarness, in domain: String) async throws -> ItemID? {
    let item = try path(Self.photo)
    while !Task.isCancelled {
      do throws(TransportError) {
        return try await harness.controller.items(of: domain).id(for: item)
      } catch .deviceDisconnected {
        await Task.yield()
      }
    }
    return nil
  }

  @Test func aCardKeepsOneLocationAcrossMethods() async throws {
    let store = itemStore()
    let mtpDevice = try await mtp()
    let adbDevice = try await adb()
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [mtpDevice], store: store, adb: adbTransport)
    await until(harness) { $0.count >= 2 }

    // First time over ADB: the card's description is matched to its volume, and the domain MTP
    // had under the description is retired for the volume's.
    await adbTransport.attach(adbDevice)
    harness.tick()
    await served(harness, by: .usbADB)
    await until(harness) { $0.contains(.remove(Self.oldCardDomain)) }
    let photo = try await cardID(harness, in: Self.cardDomain)

    // Back on MTP: the card is served under the volume's domain, with the same identities.
    await adbTransport.detach(Self.id)
    harness.tick()
    await served(harness, by: .usbFileTransfer)
    #expect(try await cardID(harness, in: Self.cardDomain) == photo)
    let adds = await harness.manager.calls.filter { call in
      if case .add(let spec) = call { return spec.identifier == Self.oldCardDomain }
      return false
    }
    #expect(adds.count == 1)
    harness.finish(keepingStore: true)

    // The match outlives the agent: MTP alone serves the card under the volume's domain.
    let again = try await mtp()
    let restarted = try AgentHarness(
      devices: [again], existing: [Self.cardDomain], store: store,
      adb: FakeTransport(devices: [], method: .usbADB))
    defer { restarted.finish() }
    await until(restarted) { $0.contains(.reconnect(Self.cardDomain)) }
    let calls = await restarted.manager.calls
    #expect(
      !calls.contains {
        if case .add(let spec) = $0 { spec.identifier == Self.oldCardDomain } else { false }
      })
    #expect(try await cardID(restarted, in: Self.cardDomain) == photo)
  }

  /// When the method changes, FileProvider is told to ask again, so it holds the new method's
  /// versions of files before it saves over them.
  @Test func aMethodChangeSignalsTheDomains() async throws {
    let mtpDevice = try await mtp()
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [mtpDevice], adb: adbTransport)
    defer { harness.finish() }
    let internalDomain = DomainNaming.identifier(for: neutralStorage("S1").id)
    await until(harness) { $0.count >= 2 }
    _ = try await harness.id(try path("/DCIM"), in: internalDomain)
    let before = await harness.manager.calls.count

    await adbTransport.attach(try await adb())
    harness.tick()
    await until(harness) { calls in
      calls.dropFirst(before).contains(.signal(internalDomain))
    }
  }
}
