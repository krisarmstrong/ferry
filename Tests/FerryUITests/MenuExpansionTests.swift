import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// One row of the menu is expanded at a time, and only the user expands one: every row is
/// collapsed each time the menu opens.
@MainActor
struct MenuExpansionTests {
  let log = CallLog()

  private static let storage = StorageInfo(
    id: StorageID(device: DeviceID(serial: "B"), key: "Internal shared storage|0"),
    description: "Internal shared storage", capacity: 64_000_000_000, free: 21_000_000_000)
  private static let waiting = device("A", model: "Pixel 8", .notSharingFiles)
  private static let first = device("B", model: "Galaxy S24", .ready([storage]), method: .usbADB)
  private static let second = device("C", model: "Pixel 9", .ready([]), method: .wifiADB)
  private static let remembered = RememberedDevice(
    id: DeviceID(serial: "R"), name: "Pixel 7", addresses: [WirelessEndpoint(parsing: "192.0.2.9")!]
  )

  /// The model after the menu opened and read the status once.
  private func openMenu(_ client: FakeClient) async -> AppModel {
    let model = AppModel(
      client: client, services: FakeServices(log: log),
      sleep: { _ in throw CancellationError() })
    await model.watchWhileMenuOpen()
    return model
  }

  @Test func everyRowStartsCollapsed() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.waiting, Self.first, Self.second], remembered: [Self.remembered])
    let model = await openMenu(client)
    #expect(model.expansion.expanded == nil)
  }

  /// A device that becomes ready, or is plugged in, while the menu is open stays collapsed.
  @Test func aDeviceThatBecomesReadyWhileOpenStaysCollapsed() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.waiting])
    let model = await openMenu(client)
    let nowReady = device("A", model: "Pixel 8", .ready([]), method: .usbADB)
    client.setStatus([nowReady, Self.first])
    await model.refresh()
    #expect(model.expansion.expanded == nil)
  }

  @Test func expandingARowCollapsesTheOther() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.first, Self.second])
    let model = await openMenu(client)
    model.toggleExpansion(.device(Self.first.id))
    model.toggleExpansion(.device(Self.second.id))
    #expect(model.expansion.expanded == .device(Self.second.id))
    #expect(!model.isExpanded(.device(Self.first.id)))
  }

  @Test func clickingTheExpandedRowCollapsesIt() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.first])
    let model = await openMenu(client)
    model.toggleExpansion(.device(Self.first.id))
    #expect(model.expansion.expanded == .device(Self.first.id))
    model.toggleExpansion(.device(Self.first.id))
    #expect(model.expansion.expanded == nil)
  }

  /// The menu refreshes every 2 s while open: the row the user opened stays open, whichever
  /// devices become ready.
  @Test func aRefreshKeepsTheOpenRowOpen() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.waiting, Self.first])
    let model = await openMenu(client)
    model.toggleExpansion(.device(Self.first.id))
    let nowReady = device("A", model: "Pixel 8", .ready([]), method: .usbADB)
    client.setStatus([nowReady, Self.first])
    await model.refresh()
    #expect(model.expansion.expanded == .device(Self.first.id))
  }

  /// The open device going away collapses its row, and no other row opens in its place.
  @Test func theOpenDeviceGoingAwayCollapsesAndNothingElseOpens() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.first, Self.second])
    let model = await openMenu(client)
    model.toggleExpansion(.device(Self.second.id))
    client.setStatus([Self.first])
    await model.refresh()
    #expect(model.expansion.expanded == nil)
  }

  @Test func reopeningTheMenuCollapsesEveryRow() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.first, Self.second])
    let model = await openMenu(client)
    model.toggleExpansion(.device(Self.second.id))
    await model.watchWhileMenuOpen()
    #expect(model.expansion.expanded == nil)
  }

  /// Ejecting the open device keeps its row open, so Mount is where the user is looking.
  @Test func ejectingTheOpenDeviceKeepsItOpen() async {
    let client = FakeClient(log: log)
    client.setStatus([Self.first, Self.second])
    let model = await openMenu(client)
    model.toggleExpansion(.device(Self.first.id))
    let ejected = device("B", model: "Galaxy S24", .ejected, method: .usbADB)
    client.setStatus([ejected, Self.second])
    await model.refresh()
    #expect(model.expansion.expanded == .device(Self.first.id))
  }

  /// A remembered device and an offer that names a known device are rows of their own, apart
  /// from that device's row.
  @Test func rememberedAndOfferRowsExpandApartFromTheDevice() async throws {
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.40"))
    let offer = UnconfirmedAddress(address: address, id: Self.first.id, name: "Galaxy S24")
    let client = FakeClient(log: log)
    client.setStatus([Self.first], remembered: [Self.remembered], unconfirmed: [offer])
    let model = await openMenu(client)
    model.toggleExpansion(.offer(address))
    #expect(model.isExpanded(.offer(address)))
    #expect(!model.isExpanded(.device(Self.first.id)))
    model.toggleExpansion(.remembered(Self.remembered.id))
    #expect(model.expansion.expanded == .remembered(Self.remembered.id))
    client.setStatus([Self.first], unconfirmed: [offer])
    await model.refresh()
    #expect(model.expansion.expanded == nil)
  }
}
