import DeviceKitTestSupport
import Foundation
import Synchronization
import Testing

@testable import ADBTransport

struct ADBTrackDevicesTests {
  static let noAdb = ADBLocator(
    environment: [:], home: "/nonexistent", isExecutable: { _ in false })

  /// The server sends each frame only once the list before it has been read: a list a slow
  /// consumer has not taken yet is replaced by the next (see `aSlowConsumerSeesOnlyTheNewestList`).
  @Test(.timeLimit(.minutes(1))) func eachFrameIsANewListAndCloseReportsNoDevicesOnce()
    async throws
  {
    let (read, reader) = AsyncStream.makeStream(of: Void.self)
    let server = try await FakeADBServer.start { peer in
      var reads = read.makeAsyncIterator()
      #expect(try await peer.request() == "host:track-devices-l")
      try await peer.okay()
      for frame in [
        "abc device usb:1-1 model:Pixel\n", "", "abc unauthorized usb:1-1\n1.2.3.4:5555 device\n",
      ] {
        try await peer.send(String(data: ADBWire.frame(frame), encoding: .utf8)!)
        await reads.next()
      }
    }
    defer { server.stop() }
    var lists: [[ADBDevice]] = []
    for await list in ADBHost(
      port: server.port, locator: Self.noAdb, launcher: { _ in },
      backoff: Backoff(initial: .seconds(30), maximum: .seconds(30))
    ).trackDevices() {
      lists.append(list)
      reader.yield()
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

  static func serve(port: UInt16?, _ listing: String, closeAfter: Duration?) async throws
    -> FakeADBServer
  {
    try await FakeADBServer.start(port: port) { peer in
      _ = try await peer.request()
      try await peer.okay()
      try await peer.send(String(data: ADBWire.frame(listing), encoding: .utf8)!)
      if let closeAfter { try await Task.sleep(for: closeAfter) }
    }
  }

  @Test func survivesServerRestartsOnTheSameStream() async throws {
    let launches = Box(0)
    let servers = Box<[FakeADBServer]>([])
    // The first server takes an OS-assigned port; restarts rebind exactly that port.
    let first = try await Self.serve(port: nil, "abc device\n", closeAfter: .milliseconds(200))
    let port = first.port
    await servers.set([first])
    let host = ADBHost(
      port: port,
      locator: ADBLocator(
        environment: [:], home: "/x", isExecutable: { $0 == "/opt/homebrew/bin/adb" }),
      launcher: { (_) async throws(ADBError) in
        let launch = await launches.value + 1
        await launches.set(launch)
        do {
          let server = try await Self.serve(
            port: port, launch == 1 ? "def device\n" : "ghi device\n",
            closeAfter: launch == 1 ? .milliseconds(200) : nil)
          await servers.set(await servers.value + [server])
        } catch {
          throw .failed("fake server: \(error)")
        }
      },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(40)))
    var seen: [[String]] = []
    for await list in host.trackDevices() {
      seen.append(list.map(\.serial))
      // Stopping the listener while a peer is connected makes the next connect an outage.
      if list.map(\.serial) == ["abc"] || list.map(\.serial) == ["def"] {
        await servers.value.last?.stopAndWait()
      }
      if seen.count == 5 { break }
    }
    #expect(seen == [["abc"], [], ["def"], [], ["ghi"]])
    #expect(await launches.value == 2)
    for server in await servers.value { server.stop() }
  }

  /// The waits between reconnects run on a clock the test moves, so the reconnects that fail
  /// are counted, not timed.
  @Test(.timeLimit(.minutes(1)))
  func persistentOutageReportsNoDevicesOnceAndStartsTheServerOnce() async throws {
    let closed = try ClosedPort()
    let launches = Box(0)
    let clock = ManualClock()
    let host = ADBHost(
      port: closed.port,
      locator: ADBLocator(
        environment: [:], home: "/x", isExecutable: { $0 == "/opt/homebrew/bin/adb" }),
      launcher: { _ in await launches.set(await launches.value + 1) },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10)), clock: clock)
    let reports = Mutex(0)
    let lists = host.trackDevices { reports.withLock { $0 += 1 } }
    // Each wait follows a failed connect, and the outage is reported and the server started
    // before the first: let ten more go by, and neither may repeat.
    for waits in 1...10 {
      await clock.waitForSleeps(waits)
      await clock.advance(by: .milliseconds(10))
    }
    await clock.waitForSleeps(11)
    #expect(reports.withLock { $0 } == 1)
    #expect(await launches.value == 1)
    var iterator = lists.makeAsyncIterator()
    #expect(await iterator.next() == [])
    withExtendedLifetime(closed) {}
  }

  /// No adb anywhere when the outage began (Ferry's fetched copy deleted): the start found
  /// nothing to run, which is no start. Once Ferry fetches adb again, the next retry starts it.
  @Test(.timeLimit(.minutes(1)))
  func anOutageWithNoAdbStartsTheServerOnceAdbArrives() async throws {
    let closed = try ClosedPort()
    let present = Mutex(false)
    let launches = Box(0)
    let host = ADBHost(
      port: closed.port,
      locator: ADBLocator(
        environment: [:], home: "/x",
        isExecutable: { $0 == "/opt/homebrew/bin/adb" && present.withLock { $0 } }),
      launcher: { _ in await launches.set(await launches.value + 1) },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10)))
    let lists = Box<[[ADBDevice]]>([])
    let consumer = Task {
      for await list in host.trackDevices() { await lists.set(await lists.value + [list]) }
    }
    #expect(try await eventually { await !lists.value.isEmpty })
    #expect(await launches.value == 0)
    present.withLock { $0 = true }
    #expect(try await eventually { await launches.value == 1 })
    consumer.cancel()
    await consumer.value
    withExtendedLifetime(closed) {}
  }

  @Test func closedConnectionsAreCancelledByTheClient() async throws {
    let connections = Box(0)
    let closed = Box(0)
    let server = try await FakeADBServer.start { peer in
      await connections.set(await connections.value + 1)
      _ = try await peer.request()
      try await peer.okay()
      try await peer.send("zzzz")
      _ = try? await peer.stream.read(exactly: 1)
      await closed.set(await closed.value + 1)
    }
    defer { server.stop() }
    let host = ADBHost(
      port: server.port, locator: Self.noAdb, launcher: { _ in },
      backoff: Backoff(initial: .seconds(5), maximum: .seconds(5)))
    for await _ in host.trackDevices() { break }
    #expect(try await eventually { await closed.value == 1 })
    #expect(await connections.value == 1)
  }

  @Test(.timeLimit(.minutes(1))) func aSlowConsumerSeesOnlyTheNewestList() async throws {
    let server = try await FakeADBServer.start { peer in
      _ = try await peer.request()
      try await peer.okay()
      for serial in ["a", "b", "c", "d"] {
        try await peer.send(String(data: ADBWire.frame("\(serial) device\n"), encoding: .utf8)!)
      }
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let (handed, handedOver) = AsyncStream.makeStream(of: Void.self)
    let stream = ADBHost(port: server.port, locator: Self.noAdb).trackDevices {
      handedOver.yield()
    }
    // All four lists are in the stream before the consumer reads any.
    var handedCount = 0
    for await _ in handed {
      handedCount += 1
      if handedCount == 4 { break }
    }
    var received: [String]?
    for await list in stream {
      received = list.map(\.serial)
      break
    }
    #expect(received == ["d"])
  }

  /// The loop reconnects only once its wait on the clock passes. Stopped, that wait is cancelled:
  /// nothing sleeps on the clock any more, and the one connection is all there is.
  @Test(.timeLimit(.minutes(1)))
  func stoppingIterationStopsTheReconnectLoop() async throws {
    let connections = Box(0)
    let server = try await FakeADBServer.start { peer in
      await connections.set(await connections.value + 1)
      _ = try await peer.request()
      try await peer.okay()
    }
    defer { server.stop() }
    let clock = ManualClock()
    let host = ADBHost(
      port: server.port, locator: Self.noAdb, launcher: { _ in },
      backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(10)), clock: clock)
    for await _ in host.trackDevices() { break }
    await clock.waitForSleeps(1)
    await clock.waitUntilNoSleeper()
    #expect(await clock.sleepCount == 1)
    #expect(await connections.value == 1)
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
