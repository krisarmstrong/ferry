import ADBTransport
import Darwin
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// macOS denies a program without Local Network access with "No route to host", which looks
/// like an unreachable device. When the agent's own check says the permission is denied, the
/// user is told to turn it on instead. When the agent itself reaches the address, the adb
/// server is the one cut off (an earlier agent's), and it is replaced.
struct WirelessADBLocalNetworkTests {
  static let address = WirelessEndpoint(parsing: "192.0.2.31:5555")!
  static let noRoute = "No route to host"

  /// The endpoints the check was asked about, and what it answers.
  final class Check: Sendable {
    let answer: LocalNetworkAccess.Reach
    let asked = Mutex<[WirelessEndpoint]>([])
    let replacements = Mutex(0)

    init(denied: Bool) { answer = denied ? .denied : .unknown }
    init(_ answer: LocalNetworkAccess.Reach) { self.answer = answer }

    func callAsFunction(_ endpoint: WirelessEndpoint) -> LocalNetworkAccess.Reach {
      asked.withLock { $0.append(endpoint) }
      return answer
    }

    func replace() -> Bool {
      replacements.withLock { $0 += 1 }
      return true
    }
  }

  static func wireless(_ adb: FakeWirelessADB, _ check: Check) -> (WirelessADB, URL) {
    let file = WirelessADBTests.storeFile()
    let wireless = WirelessADB(
      adb: adb, store: file, timing: WirelessADBTests.fast,
      localNetwork: { check($0) }, replaceCutOffServer: { check.replace() })
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

  /// The agent reaches the address but adb's server does not: the server is replaced.
  @Test(.timeLimit(.minutes(1)))
  func noRouteWhileTheAgentReachesTheAddressReplacesTheServer() async {
    let adb = FakeWirelessADB()
    await adb.set { $0.connectFailure[Self.address.argument] = Self.noRoute }
    let check = Check(.reached)
    let (wireless, file) = Self.wireless(adb, check)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(
      await wireless.connect(Self.address)
        == .failed(.adb("failed to connect to '192.0.2.31:5555': No route to host")))
    #expect(check.replacements.withLock { $0 } == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDenialDoesNotReplaceTheServer() async {
    let adb = FakeWirelessADB()
    await adb.set { $0.connectFailure[Self.address.argument] = Self.noRoute }
    let check = Check(.denied)
    let (wireless, file) = Self.wireless(adb, check)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(await wireless.connect(Self.address) == .failed(.localNetworkDenied))
    #expect(check.replacements.withLock { $0 } == 0)
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

/// The real check, against addresses that are not on a local network: it answers within its
/// bound, and never says denied.
struct LocalNetworkAccessTests {
  @Test(.timeLimit(.minutes(1)))
  func aClosedLoopbackPortIsNeitherDeniedNorReached() async throws {
    let closed = try #require(WirelessEndpoint(parsing: "127.0.0.1:9"))
    #expect(await LocalNetworkAccess.reach(closed, within: .seconds(2)) == .unknown)
  }

  @Test(.timeLimit(.minutes(1)))
  func aListeningLoopbackPortIsReached() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let endpoint = try #require(WirelessEndpoint(host: "127.0.0.1", port: listener.port))
    #expect(await LocalNetworkAccess.reach(endpoint, within: .seconds(2)) == .reached)
  }
}

/// A TCP socket listening on a free loopback port.
struct LoopbackListener {
  let socket: Int32
  let port: UInt16

  init() throws {
    let listening = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(listening >= 0 && bound == 0 && listen(listening, 4) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &length) }
    }
    socket = listening
    port = UInt16(bigEndian: address.sin_port)
  }

  func close() { Darwin.close(socket) }
}
