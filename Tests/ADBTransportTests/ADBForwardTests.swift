import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Port forwards over the host protocol: `list-forward`, `forward:` and `killforward:`, with the
/// replies adb's server gives (see `FakeAndroid.forwardRequest`).
@Suite(.timeLimit(.minutes(1)))
struct ADBForwardTests {
  static let serial = "0123456789abcdef"

  private func withHost<T>(
    _ device: FakeAndroid, _ body: (ADBHost) async throws -> T
  ) async throws -> T {
    let server = try await device.serve(serial: Self.serial)
    defer { server.stop() }
    return try await body(ADBHost(port: server.port, locator: ADBHostTests.noAdb))
  }

  @Test func theListIsThisDevicesTCPForwards() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.forwards = [
        .init(serial: Self.serial, local: "tcp:8080", remote: "tcp:80"),
        .init(serial: "other", local: "tcp:9000", remote: "tcp:9001"),
        .init(serial: Self.serial, local: "tcp:5000", remote: "localabstract:chrome"),
        .init(serial: "(reverse)", local: "tcp:7000", remote: "tcp:7001"),
        .init(serial: Self.serial, local: "tcp:2222", remote: "tcp:22"),
      ]
    }
    let listed = try await withHost(device) { try await $0.forwards(serial: Self.serial) }
    #expect(
      listed == [PortForward(local: 8080, remote: 80), PortForward(local: 2222, remote: 22)])
  }

  @Test func readingTheListNeverTrustsAMalformedLine() {
    let text = """
      S tcp:8080 tcp:80
      S tcp:99999 tcp:80
      S tcp:0 tcp:80
      S tcp:80
      garbage
      S tcp:81 tcp:abc
      S tcp:82 tcp:83 extra
      S tcp:84 tcp:85\r
      """
    #expect(
      ADBHost.parseForwards(text, serial: "S") == [
        PortForward(local: 8080, remote: 80), PortForward(local: 84, remote: 85),
      ])
  }

  @Test func aForwardIsAddedWithTheHostRequest() async throws {
    let device = FakeAndroid()
    try await withHost(device) { host in
      try await host.addForward(serial: Self.serial, PortForward(local: 8080, remote: 80))
      #expect(
        try await host.forwards(serial: Self.serial) == [PortForward(local: 8080, remote: 80)])
    }
    #expect(
      device.state.withLock { $0.tools.forwards }
        == [.init(serial: Self.serial, local: "tcp:8080", remote: "tcp:80")])
  }

  @Test func aPortThatIsTakenReportsAdbsWords() async throws {
    let device = FakeAndroid()
    device.setTools { $0.takenPorts = [8080] }
    await #expect(throws: ADBError.failed("cannot bind listener: Address already in use")) {
      try await withHost(device) { host in
        try await host.addForward(serial: Self.serial, PortForward(local: 8080, remote: 80))
      }
    }
  }

  /// Plain `forward:` on a port adb already forwards points that forward at this device, whoever
  /// made it; Ferry asks with `norebind:` so it is refused instead.
  @Test func aPortAnotherDeviceForwardsIsNeverTakenOver() async throws {
    let device = FakeAndroid()
    let theirs = FakeAndroid.Forward(serial: "other", local: "tcp:8080", remote: "tcp:9999")
    device.setTools { $0.forwards = [theirs] }
    await #expect(throws: ADBError.failed("cannot rebind existing socket")) {
      try await withHost(device) { host in
        try await host.addForward(serial: Self.serial, PortForward(local: 8080, remote: 80))
      }
    }
    #expect(device.state.withLock { $0.tools.forwards } == [theirs])
  }

  @Test func aPortThisDeviceAlreadyForwardsIsRefusedToo() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.forwards = [.init(serial: Self.serial, local: "tcp:8080", remote: "tcp:80")]
    }
    await #expect(throws: ADBError.failed("cannot rebind existing socket")) {
      try await withHost(device) { host in
        try await host.addForward(serial: Self.serial, PortForward(local: 8080, remote: 81))
      }
    }
    #expect(device.state.withLock { $0.tools.forwards.map(\.remote) } == ["tcp:80"])
  }

  @Test func aForwardIsRemovedByItsLocalPort() async throws {
    let device = FakeAndroid()
    device.setTools {
      $0.forwards = [.init(serial: Self.serial, local: "tcp:8080", remote: "tcp:80")]
    }
    try await withHost(device) { host in
      try await host.removeForward(serial: Self.serial, local: 8080)
      #expect(try await host.forwards(serial: Self.serial) == [])
    }
  }

  @Test func removingAForwardThatIsNotThereReportsAdbsWords() async throws {
    await #expect(throws: ADBError.failed("listener 'tcp:8080' not found")) {
      try await withHost(FakeAndroid()) { host in
        try await host.removeForward(serial: Self.serial, local: 8080)
      }
    }
  }

  @Test func theRulesForWhatMayBeAdded() {
    #expect(PortForward(local: 1024, remote: 1).isAllowed)
    #expect(PortForward(local: 65535, remote: 65535).isAllowed)
    #expect(!PortForward(local: 1023, remote: 80).isAllowed)
    #expect(!PortForward(local: 80, remote: 80).isAllowed)
    #expect(!PortForward(local: 0, remote: 80).isAllowed)
    #expect(!PortForward(local: 8080, remote: 0).isAllowed)
  }
}
