import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// Once a cut-off adb server is replaced, the connect that found it tries again on the new one,
/// and the remembered devices reconnect even when the new server's first list arrives while the
/// pass that replaced it is still running.
struct WirelessADBServerReplacedTests {
  static let address = "192.0.2.31:5555"
  static let endpoint = WirelessEndpoint(parsing: address)!
  typealias Base = WirelessADBTests

  @Test(.timeLimit(.minutes(1)))
  func aConnectThatReplacedTheServerTriesOnceMore() async {
    let adb = FakeWirelessADB()
    await adb.set { state in
      state.units[Self.address] = .init(info: Base.etherScope)
      state.noRouteOnce = [Self.address]
    }
    let file = Base.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(
      adb: adb, store: file, timing: Base.fast, localNetwork: { _ in .reached },
      replaceCutOffServer: { true })
    #expect(await wireless.connect(Self.endpoint) == .connected)
    #expect(await adb.calls.filter { $0 == .connect(Self.address) }.count == 2)
  }

  /// The new server never answered: Ferry says it restarted adb, not adb's stale words.
  @Test(.timeLimit(.minutes(1)))
  func aServerThatDoesNotComeBackSaysAdbWasRestarted() async {
    let adb = FakeWirelessADB()
    await adb.set { $0.noRouteOnce = [Self.address] }
    let file = Base.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(
      adb: adb, store: file, timing: Base.fast, localNetwork: { _ in .reached },
      replaceCutOffServer: {
        await adb.set { $0.serverUp = false }
        return true
      })
    #expect(await wireless.connect(Self.endpoint) == .failed(.serverRestarted))
    #expect(await adb.calls.filter { $0 == .connect(Self.address) }.count == 1)
  }

  /// The server came back while a reconnect pass was still running: its list is not dropped,
  /// and another pass runs once this one ends.
  @Test(.timeLimit(.minutes(1)))
  func aListArrivingDuringAPassRunsAnotherPass() async throws {
    let adb = FakeWirelessADB()
    let file = Base.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await WirelessADBRememberedTests.rememberEtherScope(adb, file)
    // The pass's connect is slow and finds no route, as through the server about to go.
    await adb.set { state in
      state.noRouteOnce = [Self.address]
      state.connectDelay[Self.address] = .milliseconds(300)
    }
    let wireless = WirelessADB(adb: adb, store: file, timing: Base.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(
      try await eventually { await adb.calls.filter { $0 == .connect(Self.address) }.count == 2 })
    // Mid-pass: the server goes and comes back.
    await adb.serverGone()
    await adb.set { $0.connectDelay = [:] }
    await adb.publish()
    #expect(
      try await eventually { await adb.calls.filter { $0 == .connect(Self.address) }.count == 3 })
    #expect(try await eventually { await adb.listed[Self.address] == .device })
  }

  /// After an upgrade the earlier agent's server lists the device offline: it lost the network
  /// when that agent exited, and keeps retrying in vain. That is a device to reconnect.
  @Test(.timeLimit(.minutes(1)))
  func aRememberedDeviceListedOfflineIsReconnected() async throws {
    let adb = FakeWirelessADB()
    let file = Base.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    await WirelessADBRememberedTests.rememberEtherScope(adb, file)
    await adb.set { $0.listed[Self.address] = .offline }
    let wireless = WirelessADB(adb: adb, store: file, timing: Base.fast)
    let running = Task { await wireless.run() }
    defer { running.cancel() }
    await adb.publish()
    #expect(
      try await eventually { await adb.calls.filter { $0 == .connect(Self.address) }.count == 2 })
    #expect(try await eventually { await adb.listed[Self.address] == .device })
  }
}
