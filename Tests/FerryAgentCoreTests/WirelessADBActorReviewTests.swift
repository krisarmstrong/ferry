import ADBTransport
import DeviceKit
import Foundation
import Testing

@testable import FerryAgentCore

/// Actor review: a reconnect pass the server's comeback asked for is never lost, `run` takes its
/// reconnects with it when cancelled, a cancelled wait for the server stops at once, and adb's
/// mDNS is not polled with nothing to rediscover.
@Suite(.timeLimit(.minutes(1)))
struct WirelessADBActorReviewTests {
  static let fast = WirelessADBTests.fast

  /// A store remembering `count` devices, `U1`…, each at `203.0.113.<n>:5555`.
  static func store(remembering count: Int) throws -> URL {
    let file = WirelessADBTests.storeFile()
    let devices = (1...count).map { index in
      #""U\#(index)":{"name":"Unit","addresses":[{"address":"203.0.113.\#(index):5555","learnt":"usb"}]}"#
    }
    try Data(#"{"devices":{\#(devices.joined(separator: ","))}}"#.utf8).write(to: file)
    return file
  }

  static func connects(to address: String, in adb: FakeWirelessADB) async -> Int {
    await adb.calls.filter { $0 == .connect(address) }.count
  }

  /// adb's server comes back while a reconnect pass runs, and a list read after the pass fails.
  /// The pass the comeback asked for still runs: the server sends that list once, and nothing
  /// else would start it.
  @Test func aPassAskedForDuringAPassRunsEvenIfAReadFails() async throws {
    let file = try Self.store(remembering: 1)
    defer { try? FileManager.default.removeItem(at: file) }
    let adb = FakeWirelessADB()
    await adb.holdConnects()
    let wireless = WirelessADB(adb: adb, store: file)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    while await adb.inFlight == 0, !Task.isCancelled { await Task.yield() }
    let reconnects = try #require(await wireless.reconnecting)

    await adb.serverGone()
    await adb.publish()
    while await !wireless.passRequested, !Task.isCancelled { await Task.yield() }
    await adb.set { $0.devicesFailures = 1 }
    await adb.releaseConnects()
    await reconnects.value

    #expect(await Self.connects(to: "203.0.113.1:5555", in: adb) == 2)
  }

  /// `run` follows adb until its task is cancelled, and the reconnects it started stop with it:
  /// a device still queued is not tried.
  @Test func cancellingRunStopsItsReconnects() async throws {
    let file = try Self.store(remembering: WirelessADB.reconnectLimit + 1)
    defer { try? FileManager.default.removeItem(at: file) }
    let adb = FakeWirelessADB()
    await adb.holdConnects()
    let wireless = WirelessADB(adb: adb, store: file)
    let running = Task { await wireless.run() }
    await adb.publish()
    while await adb.inFlight < WirelessADB.reconnectLimit, !Task.isCancelled { await Task.yield() }
    let reconnects = try #require(await wireless.reconnecting)

    running.cancel()
    await running.value
    await adb.releaseConnects()
    await reconnects.value

    let tried = await adb.calls.filter { if case .connect = $0 { true } else { false } }
    #expect(tried.count == WirelessADB.reconnectLimit)
  }

  /// A cancelled wait for a replaced server stops at once rather than asking adb again and again
  /// until the deadline.
  @Test func aCancelledWaitForTheServerStopsAtOnce() async {
    let adb = FakeWirelessADB()
    await adb.set { $0.serverUp = false }
    let wireless = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    let answered = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await wireless.serverAnswers()
    }.value
    #expect(!answered)
    #expect(await adb.devicesCalls == 1)
  }

  /// L3: with no device remembered there is nothing to rediscover, so the mDNS poll does not ask
  /// adb for its devices. With one remembered and missing, it still offers what mDNS lists.
  @Test func theMDNSPollAsksAdbNothingWithNothingRemembered() async throws {
    let adb = FakeWirelessADB()
    let empty = WirelessADB(adb: adb, store: WirelessADBTests.storeFile(), timing: Self.fast)
    await empty.offerFromMDNS()
    #expect(await adb.devicesCalls == 0)
    #expect(await adb.calls.isEmpty)

    let file = try Self.store(remembering: 1)
    defer { try? FileManager.default.removeItem(at: file) }
    let advertised = WirelessADBTests.endpoint("203.0.113.9:40123")
    await adb.set {
      $0.mdns = [
        ADBMDNSService(
          name: "adb-U1-abc123", type: ADBMDNSService.connectType, endpoint: advertised)
      ]
    }
    let remembering = WirelessADB(adb: adb, store: file, timing: Self.fast)
    await remembering.offerFromMDNS()
    #expect(await adb.devicesCalls == 1)
    #expect(await remembering.unconfirmed().map(\.address) == [advertised])
  }
}
