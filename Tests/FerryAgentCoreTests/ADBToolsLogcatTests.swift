import ADBTransport
import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

private let device = DeviceID(serial: "0123456789abcdef")
private let serial = "0123456789abcdef"

/// Holds the sink's callers while it is closed, as a client that reads slowly would.
private actor Gate {
  private var isOpen = true
  private var waiting: [CheckedContinuation<Void, Never>] = []
  /// How many callers the closed gate is holding.
  var held: Int { waiting.count }

  func close() { isOpen = false }

  func open() {
    isOpen = true
    for waiter in waiting { waiter.resume() }
    waiting = []
  }

  func pass() async {
    if isOpen { return }
    await withCheckedContinuation { waiting.append($0) }
  }
}

/// What the sink was given.
private final class Client: Sendable {
  private let received = Mutex<[LogBatch]>([])
  private let stopAfter = Mutex<Int?>(nil)
  let gate = Gate()

  var batches: [LogBatch] { received.withLock { $0 } }
  var lines: [String] { batches.flatMap(\.lines) }

  /// The client stops listening after this many batches.
  func stopListening(after count: Int) { stopAfter.withLock { $0 = count } }

  var sink: LogSink {
    { [self] batch in
      await gate.pass()
      let count = received.withLock { batches -> Int in
        batches.append(batch)
        return batches.count
      }
      return count < (stopAfter.withLock { $0 } ?? .max)
    }
  }
}

/// The agent's log stream: batches in order, bounded in size and queue, and ended in every way.
@Suite(.timeLimit(.minutes(1)))
struct ADBToolsLogcatTests {
  let scratch: URL
  let journal: ToolJournal

  init() throws {
    scratch = try TestScratch.folder("logcat-scratch")
    journal = ToolJournal(store: scratch.appending(path: "journal.json"))
  }

  private func makeTools(
    _ fake: FakeToolDevice,
    target: @escaping @Sendable (DeviceID) async -> String? = { _ in serial },
    limits: ADBTools.Limits = Self.fast
  ) -> ADBTools {
    ADBTools(
      device: fake, target: target, journal: journal, scratch: scratch, limits: limits)
  }

  static var fast: ADBTools.Limits {
    var limits = ADBTools.Limits()
    limits.logInterval = .milliseconds(1)
    limits.routeWatch = .milliseconds(5)
    return limits
  }

  private func start(
    _ tools: ADBTools, _ client: Client, stream: UUID = UUID()
  ) -> Task<ADBTools.Outcome, any Error> {
    Task { try await tools.streamLogcat(device, stream: stream, to: client.sink) }
  }

  @Test func linesReachTheSinkInOrderAndTheStreamEndsWhenTheDeviceEndsIt() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let client = Client()
    let run = start(makeTools(fake), client)
    await log.send(["one", "two"])
    await log.send(["three"])
    await log.end()
    #expect(try await run.value == .done)
    #expect(client.lines == ["one", "two", "three"])
    #expect(await fake.logcatsOpened == [serial])
  }

  /// Lines that are not text come through as text, never an error.
  @Test func malformedBytesAreShownNotRejected() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let client = Client()
    let run = start(makeTools(fake), client)
    await log.sendRaw([Data([0x66, 0xFF, 0xFE, 0x67]), Data("ok".utf8)])
    await log.end()
    #expect(try await run.value == .done)
    #expect(client.lines == ["f\u{FFFD}\u{FFFD}g", "ok"])
  }

  /// A burst larger than a batch goes in several, each within the line bound.
  @Test func aBatchHoldsAtMostItsLimitOfLines() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    var limits = Self.fast
    limits.logBatchLines = 100
    let client = Client()
    let run = start(makeTools(fake, limits: limits), client)
    await log.send((0..<350).map { "line \($0)" })
    await log.end()
    #expect(try await run.value == .done)
    #expect(client.batches.allSatisfy { $0.lines.count <= 100 })
    #expect(client.lines == (0..<350).map { "line \($0)" })
  }

  @Test func aBatchHoldsAtMostItsLimitOfBytes() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    var limits = Self.fast
    limits.logBatchBytes = 1_000
    let client = Client()
    let run = start(makeTools(fake, limits: limits), client)
    await log.send((0..<30).map { _ in String(repeating: "x", count: 300) })
    await log.end()
    #expect(try await run.value == .done)
    #expect(client.batches.allSatisfy { $0.lines.map(\.utf8.count).reduce(0, +) <= 1_000 + 300 })
    #expect(client.lines.count == 30)
  }

  /// A client that stops listening ends the stream and closes the device's connection.
  @Test func aClientThatStopsListeningEndsTheStream() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let client = Client()
    client.stopListening(after: 1)
    let run = start(makeTools(fake), client)
    await log.send(["one"])
    #expect(try await run.value == .done)
    #expect(try await eventually { await log.closed })
  }

  @Test func stopEndsTheStreamAndClosesIt() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let tools = makeTools(fake)
    let client = Client()
    let id = UUID()
    let run = start(tools, client, stream: id)
    await log.send(["one"])
    #expect(try await eventually { client.lines == ["one"] })
    // A stop for another stream (a window closed late) leaves this one running.
    #expect(await tools.stopLogcat(device, stream: UUID()) == .done)
    await log.send(["two"])
    #expect(try await eventually { client.lines == ["one", "two"] })
    #expect(await tools.stopLogcat(device, stream: id) == .done)
    #expect(try await run.value == .done)
    #expect(try await eventually { await log.closed })
  }

  /// The client cancelled (its app quit, or the connection dropped): the stream ends at once,
  /// even on a log that prints nothing.
  @Test func aCancelledRequestEndsASilentStream() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let tools = makeTools(fake)
    let cancellation = RequestCancellation()
    let client = Client()
    let run = Task {
      try await RequestCancellation.$current.withValue(cancellation) {
        try await tools.streamLogcat(device, stream: UUID(), to: client.sink)
      }
    }
    await log.send(["one"])
    #expect(try await eventually { client.lines == ["one"] })
    cancellation.cancel()
    #expect(try await run.value == .done)
    #expect(try await eventually { await log.closed })
  }

  /// A stop that arrives while the stream is still connecting ends it as soon as it is up.
  @Test func aStopBeforeTheStreamIsUpEndsIt() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let tools = makeTools(fake)
    let id = UUID()
    #expect(await tools.stopLogcat(device, stream: id) == .done)
    let client = Client()
    #expect(try await start(tools, client, stream: id).value == .done)
    #expect(try await eventually { await log.closed })
    #expect(client.lines.isEmpty)
  }

  /// One stream per device: a new one ends the old, which answers as stopped.
  @Test func aSecondStreamEndsTheFirst() async throws {
    let fake = FakeToolDevice()
    let first = FakeLogcat()
    let second = FakeLogcat()
    await fake.set { $0.logcats = [first, second] }
    let tools = makeTools(fake)
    let firstClient = Client()
    let (firstID, secondID) = (UUID(), UUID())
    let firstRun = start(tools, firstClient, stream: firstID)
    await first.send(["a"])
    #expect(try await eventually { firstClient.lines == ["a"] })
    let secondClient = Client()
    let secondRun = start(tools, secondClient, stream: secondID)
    #expect(try await firstRun.value == .done)
    await second.send(["b"])
    #expect(try await eventually { secondClient.lines == ["b"] })
    // The first window's stop, arriving late, does not end the second stream.
    _ = await tools.stopLogcat(device, stream: firstID)
    await second.send(["c"])
    #expect(try await eventually { secondClient.lines == ["b", "c"] })
    _ = await tools.stopLogcat(device, stream: secondID)
    #expect(try await secondRun.value == .done)
    #expect(firstClient.lines == ["a"])
  }

  @Test func aLostDeviceIsDisconnected() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let client = Client()
    let run = start(makeTools(fake), client)
    await log.send(["one"])
    await log.fail(.connectionClosed)
    await #expect(throws: TransportError.deviceDisconnected) { try await run.value }
    #expect(client.lines == ["one"])
  }

  @Test func aDeviceThatCannotStartLogcatIsDisconnected() async throws {
    let fake = FakeToolDevice()
    await fake.set { $0.failure = .deviceGone(serial) }
    await #expect(throws: TransportError.deviceDisconnected) {
      try await makeTools(fake).streamLogcat(device, stream: UUID(), to: Client().sink)
    }
  }

  @Test func aDeviceNotOnADBGetsNoLog() async throws {
    let fake = FakeToolDevice()
    let tools = makeTools(fake, target: { _ in nil })
    #expect(
      try await tools.streamLogcat(device, stream: UUID(), to: Client().sink)
        == .failed(.notOverADB))
    #expect(await fake.logcatsOpened.isEmpty)
  }

  /// An eject or a switch of method does not close the adb connection, so the stream checks the
  /// device is still served by the route it started on.
  @Test(arguments: [nil, "another-route"] as [String?])
  func aStreamEndsWhenTheDeviceIsNoLongerServedByItsRoute(now: String?) async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let route = Mutex<String?>(serial)
    let tools = makeTools(fake, target: { _ in route.withLock { $0 } })
    let client = Client()
    let run = start(tools, client)
    await log.send(["one"])
    #expect(try await eventually { client.lines == ["one"] })
    // The log is silent: the stream must end without waiting for another line.
    route.withLock { $0 = now }
    #expect(try await run.value == .failed(.notOverADB))
    #expect(try await eventually { await log.closed })
  }

  /// A client that reads slowly does not make the agent hold the whole log: the queue keeps the
  /// newest lines and says how many it dropped.
  @Test func aSlowClientGetsTheNewestLinesAndACountOfTheRest() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    var limits = Self.fast
    limits.logQueueLines = 50
    limits.logBatchLines = 1_000
    let client = Client()
    await client.gate.close()
    let run = start(makeTools(fake, limits: limits), client)
    await log.send(["first"])
    // The first batch is now with the held client; what follows queues up behind it.
    #expect(try await eventually(timeout: .seconds(5)) { await client.gate.held == 1 })
    await log.send((0..<500).map { "burst \($0)" })
    #expect(try await eventually(timeout: .seconds(5)) { await log.pendingCount == 0 })
    await client.gate.open()
    await log.end()
    #expect(try await run.value == .done)
    let last = try #require(client.batches.last)
    #expect(last.skipped == 450)
    #expect(last.lines == (450..<500).map { "burst \($0)" })
  }

  /// The device's existing log arrives in a rush when logcat starts: it goes out at the pace of
  /// the client, with nothing dropped and no pause between full batches.
  @Test func aBacklogArrivesWholeAndQuickly() async throws {
    let fake = FakeToolDevice()
    let log = FakeLogcat()
    await fake.set { $0.logcats = [log] }
    let defaults = ADBTools.Limits()
    let tools = makeTools(fake, limits: defaults)
    let client = Client()
    let clock = ContinuousClock()
    let began = clock.now
    let run = start(tools, client)
    for chunk in 0..<100 {
      await log.send((0..<100).map { "line \(chunk * 100 + $0)" })
    }
    await log.end()
    #expect(try await run.value == .done)
    #expect(client.lines == (0..<10_000).map { "line \($0)" })
    #expect(client.batches.allSatisfy { $0.skipped == 0 })
    // Twenty full batches behind the default 100 ms pause each would take over two seconds.
    #expect(clock.now - began < .seconds(1))
  }
}
