import Foundation
import Testing

@testable import ADBTransport

struct ADBTrackDevicesTests {
  static let noAdb = ADBLocator(
    environment: [:], home: "/nonexistent", isExecutable: { _ in false })

  @Test func eachFrameIsANewListAndSocketCloseFinishesTheStream() async throws {
    let server = try await FakeADBServer.start { peer in
      #expect(try await peer.request() == "host:track-devices-l")
      try await peer.okay()
      try await peer.send(String(data: ADBWire.frame("abc device model:Pixel\n"), encoding: .utf8)!)
      try await peer.send(String(data: ADBWire.frame(""), encoding: .utf8)!)
      try await peer.send(
        String(
          data: ADBWire.frame("abc unauthorized\n1.2.3.4:5555 device\n"), encoding: .utf8)!)
    }
    defer { server.stop() }
    var lists: [[ADBDevice]] = []
    for await list in ADBHost(port: server.port, locator: Self.noAdb).trackDevices() {
      lists.append(list)
    }
    #expect(
      lists == [
        [ADBDevice(serial: "abc", state: .device, isWireless: false, model: "Pixel")],
        [],
        [
          ADBDevice(serial: "abc", state: .unauthorized, isWireless: false),
          ADBDevice(serial: "1.2.3.4:5555", state: .device, isWireless: true),
        ],
      ])
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

  @Test func reconnectsAfterStartingTheServerOnce() async throws {
    let port = try await closedPort()
    let launches = Box(0)
    let servers = Box<[FakeADBServer]>([])
    let host = ADBHost(
      port: port,
      locator: ADBLocator(
        environment: [:], home: "/x", isExecutable: { $0 == "/opt/homebrew/bin/adb" }),
      launcher: { (_) async throws(ADBError) in
        await launches.set(await launches.value + 1)
        do {
          let server = try await FakeADBServer.start(port: port) { peer in
            _ = try await peer.request()
            try await peer.okay()
            try await peer.send(String(data: ADBWire.frame("abc device\n"), encoding: .utf8)!)
          }
          await servers.set([server])
        } catch {
          throw .failed("fake server: \(error)")
        }
      },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(40)))
    var first: [ADBDevice]?
    for await list in host.trackDevices() {
      first = list
      break
    }
    #expect(first?.map(\.serial) == ["abc"])
    #expect(await launches.value == 1)
    for server in await servers.value { server.stop() }
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
