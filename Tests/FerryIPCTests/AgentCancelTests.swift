import DeviceKit
import DeviceKitTestSupport
import Foundation
import Synchronization
import Testing

@testable import FerryIPC

/// How a parked request ended, as the agent saw it.
private enum Seen: Sendable, Equatable {
  /// Its client's cancel reached it.
  case cancelled
  /// The test released it, with no cancel.
  case finished
}

private final class Flag: Sendable {
  private let value = Atomic(false)
  var isSet: Bool { value.load(ordering: .acquiring) }
  func set() { value.store(true, ordering: .releasing) }
}

/// Parks every request until its cancellation is set or the test releases it, and reports which
/// came first: a transfer stopped by its client, as the agent's progress handlers would. With
/// `starts`, it says the request has its turn at the device first, as the agent does once it has
/// the domain's gate; without, the request stays queued.
private struct ParkingHandler: AgentHandling {
  let started: AsyncStream<AgentRequest>.Continuation
  let seen: AsyncStream<Seen>.Continuation
  let released: Flag
  let starts: Bool

  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse {
    let cancellation = RequestCancellation.current
    if starts { cancellation?.markStarted() }
    started.yield(request)
    while cancellation?.isCancelled != true, !released.isSet {
      try? await Task.sleep(for: .milliseconds(5))
    }
    guard cancellation?.isCancelled == true else {
      seen.yield(.finished)
      return .done
    }
    seen.yield(.cancelled)
    return .failure(.cancelled)
  }
}

private struct CancelHarness {
  let listener = NSXPCListener.anonymous()
  let delegate: AgentListenerDelegate
  let started: AsyncStream<AgentRequest>
  let seen: AsyncStream<Seen>
  /// Each lost connection the agent has dealt with.
  let lost: AsyncStream<Void>
  private let handler: ParkingHandler

  init(role: ClientRole? = nil, starts: Bool = true) {
    let (started, startedContinuation) = AsyncStream.makeStream(of: AgentRequest.self)
    let (seen, seenContinuation) = AsyncStream.makeStream(of: Seen.self)
    let (lost, lostContinuation) = AsyncStream.makeStream(of: Void.self)
    handler = ParkingHandler(
      started: startedContinuation, seen: seenContinuation, released: Flag(), starts: starts)
    delegate = AgentListenerDelegate(handler: handler, role: role) { lostContinuation.yield() }
    listener.delegate = delegate
    listener.resume()
    self.started = started
    self.seen = seen
    self.lost = lost
  }

  func client(deadline: Duration = AgentClient.replyDeadline) -> AgentClient {
    AgentClient(endpoint: listener.endpoint, replyDeadline: deadline)
  }

  /// A bare connection, to send requests and lose it as a client process would.
  func connection() throws -> (NSXPCConnection, any AgentXPC) {
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
    connection.resume()
    let proxy = try #require(connection.remoteObjectProxy as? any AgentXPC)
    return (connection, proxy)
  }

  func release() {
    handler.released.set()
  }

  func finish() {
    release()
    listener.invalidate()
  }
}

private func scratchFile() throws -> FileHandle {
  let url = TestScratch.root.appending(path: "ferry-cancel-\(UUID().uuidString)")
  try Data().write(to: url)
  return try FileHandle(forWritingTo: url)
}

private let fetch = AgentRequest.fetch(domain: "d", id: ItemID.random())
private let send = AgentRequest.sendFile(DeviceID(serial: "S1"), name: "report.pdf")

/// I6: a cancel reaches the agent's request, keyed by the request's identifier.
@Suite(.timeLimit(.minutes(1)))
struct AgentCancelTests {
  /// FileProvider cancels a fetch: the call returns at once, and the agent's transfer sees it.
  @Test func aCancelledTransferIsCancelledInTheAgent() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    let client = harness.client()
    let file = try scratchFile()
    defer { try? file.close() }
    var started = harness.started.makeAsyncIterator()
    var seen = harness.seen.makeAsyncIterator()

    let call = Task { try await client.send(fetch, file: file, progress: { _, _ in }) }
    #expect(await started.next() == fetch)
    call.cancel()

    await #expect(throws: TransportError.cancelled) { try await call.value }
    #expect(await seen.next() == .cancelled)
  }

  /// A client of the app or the FileProvider extension that goes away (quits, crashes) leaves
  /// nothing of its transfers running.
  @Test(arguments: [ClientRole?.none, .provider])
  func aLostClientCancelsItsTransfers(role: ClientRole?) async throws {
    let harness = CancelHarness(role: role)
    defer { harness.finish() }
    let file = try scratchFile()
    defer { try? file.close() }
    var started = harness.started.makeAsyncIterator()
    var seen = harness.seen.makeAsyncIterator()
    let (connection, proxy) = try harness.connection()

    proxy.send(try JSONEncoder().encode(fetch), id: "lost", file: file) { _ in }
    #expect(await started.next() == fetch)
    connection.invalidate()

    #expect(await seen.next() == .cancelled)
  }

  /// Finder's Send must finish after macOS ends the Finder Sync extension: losing it cancels
  /// nothing, and only its own cancel stops a send.
  @Test func aLostFinderSyncClientsSendGoesOn() async throws {
    let harness = CancelHarness(role: .finderSync)
    defer { harness.finish() }
    let file = try scratchFile()
    defer { try? file.close() }
    var started = harness.started.makeAsyncIterator()
    var seen = harness.seen.makeAsyncIterator()
    var lost = harness.lost.makeAsyncIterator()

    let (gone, goneProxy) = try harness.connection()
    goneProxy.send(try JSONEncoder().encode(send), id: "gone", file: file) { _ in }
    #expect(await started.next() == send)
    gone.invalidate()
    _ = await lost.next()
    harness.release()
    #expect(await seen.next() == .finished)
  }

  @Test func aFinderSyncClientsCancelStopsItsSend() async throws {
    let harness = CancelHarness(role: .finderSync)
    defer { harness.finish() }
    let file = try scratchFile()
    defer { try? file.close() }
    var started = harness.started.makeAsyncIterator()
    var seen = harness.seen.makeAsyncIterator()
    let (connection, proxy) = try harness.connection()
    defer { connection.invalidate() }

    proxy.send(try JSONEncoder().encode(send), id: "send", file: file) { _ in }
    #expect(await started.next() == send)
    proxy.cancel("send")
    #expect(await seen.next() == .cancelled)
  }

  /// A recording outlives the app that started it: its cancel does not reach it.
  @Test func aRecordingCannotBeCancelled() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    let client = harness.client()
    var started = harness.started.makeAsyncIterator()
    var seen = harness.seen.makeAsyncIterator()
    let recording = AgentRequest.startRecording(DeviceID(serial: "S1"))
    let call = Task { try await client.send(recording, file: nil) }
    #expect(await started.next() == recording)
    call.cancel()
    _ = try? await call.value
    // The agent takes a connection's messages in order: once this is answered, so was the cancel.
    let status = Task { try await client.send(.status, file: nil) }
    #expect(await started.next() == .status)
    harness.release()
    #expect(await seen.next() == .finished)
    _ = try? await status.value
  }

  /// T3: a metadata call the agent started and never answers fails as an agent not answering,
  /// which `ErrorMapping` makes `.serverUnreachable` (see `ErrorMappingTests`), and the client
  /// cancels it in the agent.
  @Test func aStartedCallWithNoReplyFailsAsNotResponding() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    let client = harness.client(deadline: .milliseconds(100))
    var seen = harness.seen.makeAsyncIterator()
    await #expect(throws: TransportError.agentNotResponding) {
      try await client.send(.list(domain: "d", folder: .root), file: nil)
    }
    #expect(await seen.next() == .cancelled)
  }

  /// A metadata call waiting for its turn (behind a transfer) has no deadline yet.
  @Test func aQueuedCallIsNotTimedOut() async throws {
    let harness = CancelHarness(starts: false)
    defer { harness.finish() }
    let client = harness.client(deadline: .milliseconds(100))
    var started = harness.started.makeAsyncIterator()
    let call = Task { try await client.send(.list(domain: "d", folder: .root), file: nil) }
    #expect(await started.next() == .list(domain: "d", folder: .root))
    // Queued for four deadlines.
    try await Task.sleep(for: .milliseconds(400))
    harness.release()
    #expect(try await call.value == .done)
  }

  /// A network connect tries each address with adb's own 30 s limit, in turn: it has no deadline.
  @Test func networkConnectsHaveNoDeadline() throws {
    let id = DeviceID(serial: "S1")
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.31", defaultPort: 5555))
    let connects: [AgentRequest] = [
      .connectAddress(address), .connectWireless(id), .enableWireless(id),
      .confirmWireless(UnconfirmedAddress(address: address, id: id, name: "LinkRunner")),
    ]
    #expect(connects.allSatisfy { $0.mayTakeLong })
    #expect(!AgentRequest.forgetWireless(id).mayTakeLong)
    #expect(!AgentRequest.startRecording(id).isCancellable)
  }

  /// A transfer, which reports its progress, has no deadline however long it runs.
  @Test func aTransferIsNotTimedOut() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    let client = harness.client(deadline: .milliseconds(100))
    let file = try scratchFile()
    defer { try? file.close() }
    var started = harness.started.makeAsyncIterator()
    let call = Task { try await client.send(fetch, file: file, progress: { _, _ in }) }
    #expect(await started.next() == fetch)
    try await Task.sleep(for: .milliseconds(400))
    harness.release()
    #expect(try await call.value == .done)
  }
}
