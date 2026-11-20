import AppKit
import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// What a click on a detail line copies: its address, or with Option every detail, and the word
/// that shows in place of the line's value for a moment.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelDetailCopyTests {
  let log = CallLog()
  let id = DeviceID(serial: "0123456789abcdef")
  static let info = AppModelDetailsTests.info
  static let line = AppModelDetailsTests.line

  private func client() -> FakeClient {
    let client = FakeClient(log: log)
    client.setStatus([device(id.serial, model: "EtherScope-nXG", .ready([]), method: .wifiADB)])
    client.infoReply.withLock { $0 = .deviceInfo(Self.info) }
    return client
  }

  private func model(
    _ client: FakeClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
  ) -> AppModel {
    AppModel(client: client, services: FakeServices(log: log), sleep: sleep)
  }

  /// The menu's first status expanded the device, and its read has started.
  private func expanded(_ client: FakeClient) async -> AppModel {
    let model = model(client)
    await model.refresh()
    model.loadExpandedDetailsIfDue()
    return model
  }

  /// A click copies the address and shows "Copied" until the injected clock's 1.5 s have passed.
  @Test func clickingALineCopiesItsAddress() async throws {
    let sleeps = HeldSleeps()
    // A failed expectation must not strand a copy's sleep, which the test awaits on its way out.
    defer { sleeps.wakeAll() }
    let model = model(client(), sleep: sleeps.sleep)
    await model.refresh()
    async let copied: Void = model.copyAddress(Self.line, on: id)
    try #require(await sleeps.waitForSleeper())
    #expect(log.all.contains("copy 192.0.2.159"))
    // VoiceOver hears it too: the line's new value is not where its focus is.
    #expect(log.all.contains("announce Copied"))
    #expect(model.copied(Self.line, on: id) == .line)
    #expect(sleeps.durations == [.milliseconds(1500)])
    sleeps.wakeAll()
    await copied
    #expect(model.copied(Self.line, on: id) == nil)
  }

  /// A second click keeps "Copied" for its own 1.5 s: the first click's timer does not end it.
  @Test func aSecondCopyIsNotClearedByTheFirst() async throws {
    let sleeps = HeldSleeps()
    // A failed expectation must not strand a copy's sleep, which the test awaits on its way out.
    defer { sleeps.wakeAll() }
    let model = model(client(), sleep: sleeps.sleep)
    await model.refresh()
    async let first: Void = model.copyAddress(Self.line, on: id)
    try #require(await sleeps.waitForSleeper())
    async let second: Void = model.copyAddress(Self.line, on: id)
    try #require(await sleeps.waitForSleeper(count: 2))
    sleeps.wakeFirst()
    await first
    #expect(model.copied(Self.line, on: id) == .line)
    sleeps.wakeAll()
    await second
    #expect(model.copied(Self.line, on: id) == nil)
  }

  /// A port with no address, shown as plain text.
  static let notConnected = DevicePresentation.DetailLine(
    id: "eth0", label: "Wired Management", address: nil)

  /// Option-click on an address line copies everything the device said, in the full format
  /// (every address including IPv6), and shows "Copied All" on that line for 1.5 s.
  @Test func optionClickCopiesEveryDetail() async throws {
    let line = Self.line
    let sleeps = HeldSleeps()
    // A failed expectation must not strand a copy's sleep, which the test awaits on its way out.
    defer { sleeps.wakeAll() }
    let model = model(client(), sleep: sleeps.sleep)
    await model.refresh()
    model.loadExpandedDetailsIfDue()
    await model.detailsSettled()
    async let copied: Void = model.click(line, modifiers: [.option], on: id)
    try #require(await sleeps.waitForSleeper())
    #expect(log.all.contains("copy \(DevicePresentation.detailsText(Self.info))"))
    #expect(DevicePresentation.detailsText(Self.info).contains("2001:db8::159"))
    #expect(log.all.contains("announce Copied All"))
    #expect(model.copied(line, on: id) == .all)
    #expect(sleeps.durations == [.milliseconds(1500)])
    sleeps.wakeAll()
    await copied
    #expect(model.copied(line, on: id) == nil)
  }

  /// A line with no address copies nothing, Option or not.
  @Test(arguments: [false, true])
  func clickingALineWithNoAddressCopiesNothing(option: Bool) async {
    let model = await expanded(client())
    await model.detailsSettled()
    await model.click(Self.notConnected, modifiers: option ? [.option] : [], on: id)
    #expect(!log.all.contains { $0.hasPrefix("copy ") })
    #expect(model.copied(Self.notConnected, on: id) == nil)
  }

  /// Before the details are read there is nothing to copy.
  @Test func optionClickBeforeTheDetailsCopiesNothing() async {
    let model = model(client())
    await model.refresh()
    await model.click(Self.line, modifiers: [.option], on: id)
    #expect(!log.all.contains { $0.hasPrefix("copy ") })
  }

  /// A plain click after an Option-click shows "Copied" for its own 1.5 s.
  @Test func aPlainClickReplacesCopiedAll() async throws {
    let sleeps = HeldSleeps()
    // A failed expectation must not strand a copy's sleep, which the test awaits on its way out.
    defer { sleeps.wakeAll() }
    let model = model(client(), sleep: sleeps.sleep)
    await model.refresh()
    model.loadExpandedDetailsIfDue()
    await model.detailsSettled()
    async let all: Void = model.click(Self.line, modifiers: [.option], on: id)
    try #require(await sleeps.waitForSleeper())
    async let one: Void = model.click(Self.line, modifiers: [], on: id)
    try #require(await sleeps.waitForSleeper(count: 2))
    #expect(model.copied(Self.line, on: id) == .line)
    #expect(log.all.last == "announce Copied")
    sleeps.wakeFirst()
    await all
    #expect(model.copied(Self.line, on: id) == .line)
    sleeps.wakeAll()
    await one
    #expect(model.copied(Self.line, on: id) == nil)
  }
}
