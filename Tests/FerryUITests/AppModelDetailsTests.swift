import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryUI

/// The details an expanded device shows inline: when they are read, how often, and what a click
/// copies.
@MainActor
struct AppModelDetailsTests {
  let log = CallLog()
  let clock = TestClock()
  let id = DeviceID(serial: "0123456789abcdef")
  static let info = AndroidDeviceInfo(
    model: "EtherScope-nXG", androidVersion: "8.1.0", build: "OPM1", serial: "0123456789abcdef",
    battery: .init(level: 100, state: .full),
    addresses: [
      .init(interface: "wlan0", address: "192.0.2.159"),
      .init(interface: "wlan0", address: "2001:db8::159"),
    ], storage: nil)
  static let line = DevicePresentation.DetailLine(
    id: "wlan0", label: "Wi-Fi Management", address: "192.0.2.159")

  private func client(method: ConnectionMethod = .wifiADB) -> FakeClient {
    let client = FakeClient(log: log)
    client.setStatus([device(id.serial, model: "EtherScope-nXG", .ready([]), method: method)])
    client.infoReply.withLock { $0 = .deviceInfo(Self.info) }
    return client
  }

  private func model(
    _ client: FakeClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
  ) -> AppModel {
    AppModel(client: client, services: FakeServices(log: log), sleep: sleep, now: clock.now)
  }

  private var reads: Int { log.all.filter { $0 == "deviceInfo \(id.serial)" }.count }

  /// The menu's first status expanded the device, and its read has started.
  private func expanded(_ client: FakeClient) async -> AppModel {
    let model = model(client)
    await model.refresh()
    #expect(model.isExpanded(.device(id)))
    model.loadExpandedDetailsIfDue()
    return model
  }

  @Test func expandingADeviceReadsItsDetails() async {
    let model = model(client())
    await model.refresh()
    model.toggleExpansion(.device(id))
    await model.detailsSettled()
    #expect(reads == 0)
    model.toggleExpansion(.device(id))
    #expect(model.shownDetails(of: id) == .loading)
    await model.detailsSettled()
    #expect(model.shownDetails(of: id) == .loaded(Self.info))
    #expect(reads == 1)
  }

  /// Read again at most once every 10 s, and never while a read is running.
  @Test func detailsAreReadAtMostEveryTenSeconds() async {
    let model = await expanded(client())
    model.loadExpandedDetailsIfDue()
    await model.detailsSettled()
    #expect(reads == 1)
    clock.advance(.seconds(9))
    model.loadExpandedDetailsIfDue()
    await model.detailsSettled()
    #expect(reads == 1)
    clock.advance(.seconds(1))
    model.loadExpandedDetailsIfDue()
    #expect(model.shownDetails(of: id) == .loaded(Self.info))
    await model.detailsSettled()
    #expect(reads == 2)
  }

  /// While the menu is open, the expanded device is read on its first status and every 10 s
  /// after, on the menu's 2 s cadence: at 0, 10 and 20 s of 22.
  @Test func anOpenMenuRefreshesTheExpandedDevice() async {
    let holder = ModelHolder()
    let ticks = Mutex(0)
    let clock = clock
    let model = model(client()) { _ in
      clock.advance(.seconds(2))
      await holder.model?.detailsSettled()
      let tick = ticks.withLock { tick in
        tick += 1
        return tick
      }
      if tick > 11 { throw CancellationError() }
    }
    holder.model = model
    await model.watchWhileMenuOpen()
    #expect(log.all.filter { $0 == "status" }.count == 12)
    #expect(reads == 3)
  }

  /// Nothing is read for a device without tools, collapsed or not, nor while the menu is closed.
  @Test func nothingIsReadWithoutTheMenuOrTools() async {
    let model = await expanded(client(method: .usbFileTransfer))
    await model.detailsSettled()
    #expect(model.shownDetails(of: id) == DetailsShown.hidden)

    let closed = await expanded(client())
    await closed.detailsSettled()
    clock.advance(.seconds(30))
    for _ in 0..<3 { await closed.refresh() }
    await closed.detailsSettled()
    #expect(reads == 1)

    closed.toggleExpansion(.device(id))
    closed.loadExpandedDetailsIfDue()
    await closed.detailsSettled()
    #expect(reads == 1)
  }

  /// A failed read shows nothing at all; a later failure keeps what was read before.
  @Test func aFailureShowsNothingExtra() async {
    let client = client()
    client.infoReply.withLock { $0 = .toolFailed(.notOverADB) }
    let model = await expanded(client)
    await model.detailsSettled()
    #expect(model.shownDetails(of: id) == DetailsShown.hidden)
    #expect(model.actionError == nil)

    client.infoReply.withLock { $0 = .deviceInfo(Self.info) }
    clock.advance(.seconds(10))
    model.loadExpandedDetailsIfDue()
    await model.detailsSettled()
    client.infoReply.withLock { $0 = .failure(.deviceDisconnected) }
    clock.advance(.seconds(10))
    model.loadExpandedDetailsIfDue()
    await model.detailsSettled()
    #expect(model.shownDetails(of: id) == .loaded(Self.info))
  }

  /// A device that goes away takes its details with it.
  @Test func aDeviceThatGoesAwayIsForgotten() async {
    let client = client()
    let model = await expanded(client)
    await model.detailsSettled()
    client.setStatus([])
    await model.refresh()
    #expect(model.shownDetails(of: id) == DetailsShown.hidden)
  }

  /// A click copies the address and shows "Copied" until the injected clock's 1.5 s have passed.
  @Test func clickingALineCopiesItsAddress() async {
    let sleeps = HeldSleeps()
    let model = model(client(), sleep: sleeps.sleep)
    await model.refresh()
    async let copied: Void = model.copyAddress(Self.line, on: id)
    await sleeps.waitForSleeper()
    #expect(log.all.contains("copy 192.0.2.159"))
    #expect(model.isCopied(Self.line, on: id))
    #expect(sleeps.durations == [.milliseconds(1500)])
    sleeps.wakeAll()
    await copied
    #expect(!model.isCopied(Self.line, on: id))
  }

  /// A second click keeps "Copied" for its own 1.5 s: the first click's timer does not end it.
  @Test func aSecondCopyIsNotClearedByTheFirst() async {
    let sleeps = HeldSleeps()
    let model = model(client(), sleep: sleeps.sleep)
    await model.refresh()
    async let first: Void = model.copyAddress(Self.line, on: id)
    await sleeps.waitForSleeper()
    async let second: Void = model.copyAddress(Self.line, on: id)
    await sleeps.waitForSleeper(count: 2)
    sleeps.wakeFirst()
    await first
    #expect(model.isCopied(Self.line, on: id))
    sleeps.wakeAll()
    await second
    #expect(!model.isCopied(Self.line, on: id))
  }

  @Test func copyAllDetailsCopiesTheFullText() async {
    let model = await expanded(client())
    model.copyAllDetails(of: id)
    #expect(!log.all.contains { $0.hasPrefix("copy ") })
    await model.detailsSettled()
    model.copyAllDetails(of: id)
    #expect(log.all.contains("copy \(DevicePresentation.detailsText(Self.info))"))
  }
}

/// Lets a sleep closure reach the model it was given to.
@MainActor final class ModelHolder {
  var model: AppModel?
}

/// Sleeps that last until the test wakes them, recording what each asked for.
final class HeldSleeps: Sendable {
  private struct State {
    var held: [CheckedContinuation<Void, Never>] = []
    var durations: [Duration] = []
    var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  }

  private let state = Mutex(State())

  var durations: [Duration] { state.withLock { $0.durations } }

  var sleep: @Sendable (Duration) async throws -> Void {
    { duration in
      await withCheckedContinuation { continuation in
        let ready = self.state.withLock { state in
          state.held.append(continuation)
          state.durations.append(duration)
          let count = state.durations.count
          let ready = state.waiters.filter { $0.count <= count }
          state.waiters.removeAll { $0.count <= count }
          return ready
        }
        for waiter in ready { waiter.continuation.resume() }
      }
    }
  }

  /// Returns once `count` sleeps have been asked for.
  func waitForSleeper(count: Int = 1) async {
    await withCheckedContinuation { continuation in
      let now = state.withLock { state in
        guard state.durations.count < count else { return true }
        state.waiters.append((count, continuation))
        return false
      }
      if now { continuation.resume() }
    }
  }

  func wakeFirst() {
    let first = state.withLock { $0.held.isEmpty ? nil : $0.held.removeFirst() }
    first?.resume()
  }

  func wakeAll() {
    let held = state.withLock { state in
      defer { state.held = [] }
      return state.held
    }
    for continuation in held { continuation.resume() }
  }
}
