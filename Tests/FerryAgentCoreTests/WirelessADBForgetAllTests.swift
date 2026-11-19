import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Remove Ferry forgets every device on the network, including one remembered while it runs,
/// and every address waiting for the user.
@Suite(.timeLimit(.minutes(1)))
struct WirelessADBForgetAllTests {
  static let fast = WirelessADBTests.fast
  static let linkRunner = WirelessADBTests.linkRunner
  static let etherScope = WirelessADBTests.etherScope

  /// An address offered for a located device that was never remembered is withdrawn too.
  @Test func forgetAllWithdrawsOffersForUnrememberedDevices() async throws {
    let adb = FakeWirelessADB()
    let address = WirelessADBTests.endpoint("192.0.2.40")
    await adb.set { $0.units[address.argument] = .init(info: Self.linkRunner) }
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(
      adb: adb, store: file, timing: Self.fast,
      located: { $0 == Self.linkRunner.id ? "LinkRunner-100G" : nil })
    #expect(await wireless.connect(address) == .needsConfirmation(address))
    try #require(await wireless.unconfirmed().count == 1)

    await wireless.forgetAll()

    #expect(await wireless.unconfirmed().isEmpty)
  }

  /// A device connected while an earlier one is being forgotten is forgotten as well, not left
  /// out by a list of devices read before it was remembered.
  @Test func forgetAllForgetsADeviceRememberedWhileItRuns() async throws {
    let adb = FakeWirelessADB()
    let first = WirelessADBTests.endpoint("192.0.2.31")
    let second = WirelessADBTests.endpoint("192.0.2.32")
    await adb.set {
      $0.units[first.argument] = .init(info: Self.etherScope)
      $0.units[second.argument] = .init(info: Self.linkRunner)
    }
    let file = WirelessADBTests.storeFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let wireless = WirelessADB(adb: adb, store: file, timing: Self.fast)
    #expect(await wireless.connect(first) == .connected)

    await adb.holdDisconnects()
    let forgetting = Task { await wireless.forgetAll() }
    #expect(try await eventually { await adb.calls.contains(.disconnect(first.argument)) })
    let connecting = Task { await wireless.connect(second) }
    #expect(try await eventually { await wireless.gate.waiting == 1 })
    await adb.releaseDisconnects()
    #expect(await connecting.value == .connected)
    await forgetting.value

    #expect(await wireless.remembered().isEmpty)
  }
}
