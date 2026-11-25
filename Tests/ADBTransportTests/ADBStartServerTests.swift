import Foundation
import Testing

@testable import ADBTransport

/// Ferry starts a server only when none answers, with the adb the locator finds. The launcher
/// stands in for `ADBServerKeeper`, so no adb ever runs.
struct ADBStartServerTests {
  /// A locator that finds an adb the launcher below stands in for, so no adb ever runs.
  static let findsAdb = ADBLocator(
    environment: [:], home: "/nonexistent", isExecutable: { $0 == "/opt/homebrew/bin/adb" })

  /// A server already answering is used as it is: Ferry never runs another adb's start-server
  /// against it, which could make that adb restart the server.
  @Test func aServerThatAnswersIsNeverStartedAgain() async throws {
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:version")
      try await peer.answer("0029")
    }
    defer { server.stop() }
    let launched = Box(0)
    let host = ADBHost(
      port: server.port, locator: Self.findsAdb,
      launcher: { _ in await launched.set(launched.value + 1) }, backoff: Backoff())
    try await host.startServer()
    #expect(await launched.value == 0)
  }

  @Test func withNoServerTheLocatedAdbStartsOne() async throws {
    let launched = Box<[String]>([])
    let host = ADBHost(
      port: 5037, locator: Self.findsAdb,
      launcher: { adb in await launched.set(launched.value + [adb.path]) }, backoff: Backoff(),
      opener: ADBHost.refusing)
    try await host.startServer()
    #expect(await launched.value == ["/opt/homebrew/bin/adb"])
  }
}
