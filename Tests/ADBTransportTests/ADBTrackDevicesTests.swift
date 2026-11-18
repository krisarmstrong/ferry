import Foundation
import Testing

@testable import ADBTransport

struct ADBTrackDevicesTests {
  static let noAdb = ADBLocator(
    environment: [:], home: "/nonexistent", isExecutable: { _ in false })

  @Test func eachFrameIsANewListAndCloseReportsNoDevicesOnce() async throws {
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:track-devices-l")
      try await peer.okay()
      try await peer.send("0017abc device model:Pixel\n0000")
      try await peer.send(
        String(data: ADBWire.frame("abc unauthorized\n1.2.3.4:5555 device\n"), encoding: .utf8)!)
    }
    defer { server.stop() }
    var lists: [[ADBDevice]] = []
    for await list in ADBHost(
      port: server.port, locator: Self.noAdb, launcher: { _ in },
      backoff: Backoff(initial: .milliseconds(500), maximum: .milliseconds(500))
    ).trackDevices() {
      lists.append(list)
      if lists.count == 4 { break }
    }
    #expect(
      lists == [
        [ADBDevice(serial: "abc", state: .device, isWireless: false, model: "Pixel")],
        [],
        [
          ADBDevice(serial: "abc", state: .unauthorized, isWireless: false),
          ADBDevice(serial: "1.2.3.4:5555", state: .device, isWireless: true),
        ],
        [],
      ])
  }

  static func serve(port: UInt16, _ listing: String, closeAfter: Duration?) async throws
    -> FakeADBServer
  {
    try await FakeADBServer.start(port: port) { peer in
      _ = try await peer.request()
      try await peer.okay()
      try await peer.send(String(data: ADBWire.frame(listing), encoding: .utf8)!)
      if let closeAfter { try await Task.sleep(for: closeAfter) }
    }
  }

  @Test func survivesServerRestartOnTheSameStream() async throws {
    let port = try await closedPort()
    let launches = Box(0)
    let servers = Box<[FakeADBServer]>([])
    let first = try await Self.serve(port: port, "abc device\n", closeAfter: .milliseconds(50))
    let host = ADBHost(
      port: port,
      locator: ADBLocator(
        environment: [:], home: "/x", isExecutable: { $0 == "/opt/homebrew/bin/adb" }),
      launcher: { (_) async throws(ADBError) in
        await launches.set(await launches.value + 1)
        do {
          await servers.set([try await Self.serve(port: port, "def device\n", closeAfter: nil)])
        } catch {
          throw .failed("fake server: \(error)")
        }
      },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(40)))
    var seen: [[String]] = []
    for await list in host.trackDevices() {
      seen.append(list.map(\.serial))
      if seen.count == 1 { first.stop() }
      if seen.count == 3 { break }
    }
    #expect(seen == [["abc"], [], ["def"]])
    #expect(await launches.value == 1)
    for server in await servers.value { server.stop() }
  }

  @Test func missingServerReportsNoDevicesAndStartsItOnce() async throws {
    let port = try await closedPort()
    let launches = Box(0)
    let host = ADBHost(
      port: port,
      locator: ADBLocator(
        environment: [:], home: "/x", isExecutable: { $0 == "/opt/homebrew/bin/adb" }),
      launcher: { _ in await launches.set(await launches.value + 1) },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(20)))
    for await list in host.trackDevices() {
      #expect(list.isEmpty)
      break
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(await launches.value == 1)
  }

  @Test func stoppingIterationStopsTheReconnectLoop() async throws {
    let connections = Box(0)
    let server = try await FakeADBServer.start { peer in
      await connections.set(await connections.value + 1)
      _ = try await peer.request()
      try await peer.okay()
    }
    defer { server.stop() }
    let host = ADBHost(
      port: server.port, locator: Self.noAdb, launcher: { _ in },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10)))
    for await _ in host.trackDevices() { break }
    try await Task.sleep(for: .milliseconds(100))
    let settled = await connections.value
    try await Task.sleep(for: .milliseconds(300))
    #expect(await connections.value == settled)
  }

  @Test func cancellingTheConsumerClosesTheSocket() async throws {
    let hungUp = Box(false)
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.okay()
      try await peer.send(String(data: ADBWire.frame("abc device\n"), encoding: .utf8)!)
      _ = try? await peer.stream.read(exactly: 1)
      await hungUp.set(true)
    }
    defer { server.stop() }
    for await _ in ADBHost(port: server.port, locator: Self.noAdb).trackDevices() { break }
    for _ in 0..<100 where await !hungUp.value { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await hungUp.value)
  }

  @Test func backoffDoublesFromOneSecondToThirtyAndResets() {
    var backoff = Backoff()
    let steps = (0..<7).map { _ in backoff.next() }
    #expect(
      steps == [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30),
        .seconds(30),
      ])
    backoff.reset()
    #expect(backoff.next() == .seconds(1))
  }
}
