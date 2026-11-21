import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// macOS denies a program without Local Network access with "No route to host", which looks
/// like an unreachable device. When the agent's own check says the permission is denied, the
/// user is told to turn it on instead.
struct WirelessADBLocalNetworkTests {
  static let address = WirelessEndpoint(parsing: "192.0.2.31:5555")!
  static let noRoute = "No route to host"

  /// The endpoints the check was asked about, and what it answers.
  final class Check: Sendable {
    let denied: Bool
    let asked = Mutex<[WirelessEndpoint]>([])

    init(denied: Bool) { self.denied = denied }

    func callAsFunction(_ endpoint: WirelessEndpoint) -> Bool {
      asked.withLock { $0.append(endpoint) }
      return denied
    }
  }

  static func wireless(_ adb: FakeWirelessADB, _ check: Check) -> (WirelessADB, URL) {
    let file = WirelessADBTests.storeFile()
    let wireless = WirelessADB(
      adb: adb, store: file, timing: WirelessADBTests.fast,
      localNetworkDenied: { check($0) })
    return (wireless, file)
  }

  @Test(.timeLimit(.minutes(1)))
  func noRouteWhileTheCheckSaysDeniedAsksForLocalNetworkAccess() async {
    let adb = FakeWirelessADB()
    await adb.set { $0.connectFailure[Self.address.argument] = Self.noRoute }
    let check = Check(denied: true)
    let (wireless, file) = Self.wireless(adb, check)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(await wireless.connect(Self.address) == .failed(.localNetworkDenied))
    #expect(check.asked.withLock { $0 } == [Self.address])
  }

  /// A device that is really unreachable keeps adb's words.
  @Test(.timeLimit(.minutes(1)))
  func noRouteWithLocalNetworkAccessKeepsAdbsWords() async {
    let adb = FakeWirelessADB()
    await adb.set { $0.connectFailure[Self.address.argument] = Self.noRoute }
    let (wireless, file) = Self.wireless(adb, Check(denied: false))
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(
      await wireless.connect(Self.address)
        == .failed(.adb("failed to connect to '192.0.2.31:5555': No route to host")))
  }

  /// Only "No route to host" is what a denial looks like: other failures are not checked.
  @Test(.timeLimit(.minutes(1)))
  func otherFailuresAreNotChecked() async {
    let adb = FakeWirelessADB()
    let check = Check(denied: true)
    let (wireless, file) = Self.wireless(adb, check)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(
      await wireless.connect(Self.address)
        == .failed(.adb("failed to connect to '192.0.2.31:5555': Connection refused")))
    #expect(check.asked.withLock { $0 }.isEmpty)
  }

  /// Pairing reaches the device's pairing port first, and is denied the same way.
  @Test(.timeLimit(.minutes(1)))
  func pairingDeniedLocalNetworkAccessAsksForIt() async throws {
    let adb = FakeWirelessADB()
    let pairing = try #require(WirelessEndpoint(parsing: "192.0.2.31:37099"))
    await adb.set {
      $0.pairOutcome = .failed("failed to connect to '192.0.2.31:37099': No route to host")
    }
    let check = Check(denied: true)
    let (wireless, file) = Self.wireless(adb, check)
    defer { try? FileManager.default.removeItem(at: file) }
    let code = try #require(PairingCode("123456"))
    #expect(await wireless.pair(pairing, code: code) == .failed(.localNetworkDenied))
    #expect(check.asked.withLock { $0 } == [pairing])
  }
}

/// The real check, against an address that is not on a local network: it answers within its
/// bound, and never says denied.
struct LocalNetworkAccessTests {
  @Test(.timeLimit(.minutes(1)))
  func loopbackIsNeverDenied() async throws {
    let closed = try #require(WirelessEndpoint(parsing: "127.0.0.1:9"))
    #expect(await LocalNetworkAccess.isDenied(closed, within: .seconds(2)) == false)
  }
}
