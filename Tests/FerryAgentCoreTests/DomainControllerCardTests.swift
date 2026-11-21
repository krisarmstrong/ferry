import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Android's MTP server sends no volume ID, so MTP knows an SD card only by its description,
/// which every card of a vendor shares. A card is therefore never matched across methods: it has
/// a Finder location per method, and another card never takes its location.
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

  /// Waits for what a test expects next while the hub's and the controller's clocks move on, as
  /// time does: a retry or back-off the run happens to take (a busy machine orders events
  /// differently) passes instead of waiting forever on a clock nothing moves.
  func passing<T>(_ harness: AgentHarness, _ wait: () async throws -> T) async rethrows -> T {
    try await harness.retryClock.advancing(by: .seconds(1)) {
      try await harness.clock.advancing(by: .seconds(1)) { try await wait() }
    }
  }

  func until(_ harness: AgentHarness, _ condition: ([FakeDomainManager.Call]) -> Bool) async {
    await passing(harness) {
      while await !condition(harness.manager.calls), !Task.isCancelled { await Task.yield() }
    }
  }

  func served(_ harness: AgentHarness, by method: ConnectionMethod) async {
    await passing(harness) {
      while await harness.hub.devices().first?.method != method, !Task.isCancelled {
        await Task.yield()
      }
    }
  }

  func cardID(_ harness: AgentHarness, in domain: String) async throws -> ItemID? {
    let item = try path(Self.photo)
    return try await passing(harness) { () async throws -> ItemID? in
      while !Task.isCancelled {
        do throws(TransportError) {
          return try await harness.controller.items(of: domain).id(for: item)
        } catch .deviceDisconnected {
          await Task.yield()
        }
      }
      return nil
    }
  }

  /// MTP knows the card only by its description, ADB by its volume ID: the card has a location
  /// per method. Switching method disconnects one and reconnects the other; neither is removed,
  /// and each keeps its item identities.
  @Test func aCardHasALocationPerMethod() async throws {
    let mtpDevice = try await mtp()
    let adbTransport = FakeTransport(devices: [], method: .usbADB)
    let harness = try AgentHarness(devices: [mtpDevice], adb: adbTransport)
    defer { harness.finish() }
    await until(harness) { $0.count >= 2 }
    let overMTP = try await cardID(harness, in: Self.oldCardDomain)

    await adbTransport.attach(try await adb())
    harness.tick()
    await served(harness, by: .usbADB)
    await until(harness) { $0.contains(.disconnect(Self.oldCardDomain)) }
    let overADB = try await cardID(harness, in: Self.cardDomain)

    await adbTransport.detach(Self.id)
    harness.tick()
    await served(harness, by: .usbFileTransfer)
    #expect(try await cardID(harness, in: Self.oldCardDomain) == overMTP)
    await until(harness) { $0.contains(.disconnect(Self.cardDomain)) }
    let removes = await harness.manager.calls.filter {
      if case .remove = $0 { return true }
      return false
    }
    #expect(removes.isEmpty)
    #expect(overADB != nil)
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
