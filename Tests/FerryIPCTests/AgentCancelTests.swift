import DeviceKit
import DeviceKitTestSupport
import Foundation
import Synchronization
import Testing

@testable import FerryIPC

/// What the agent saw of a request's cancellation.
private enum Seen: Sendable, Equatable {
  /// The request ran with no cancellation: it cannot be cancelled.
  case notCancellable
  case cancelled
}

private final class Flag: Sendable {
  private let value = Atomic(false)
  var isSet: Bool { value.load(ordering: .acquiring) }
  func set() { value.store(true, ordering: .releasing) }
}

/// Parks every request until its cancellation is set or the test releases it, and reports what
/// it saw: a transfer stopped by its client, as the agent's progress handlers would.
private struct ParkingHandler: AgentHandling {
  let started: AsyncStream<AgentRequest>.Continuation
  let seen: AsyncStream<Seen>.Continuation
  let released: Flag

  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse {
    let cancellation = RequestCancellation.current
    started.yield(request)
    guard let cancellation else {
      seen.yield(.notCancellable)
      while !released.isSet { try? await Task.sleep(for: .milliseconds(5)) }
      return .done
    }
    while !cancellation.isCancelled, !released.isSet {
      try? await Task.sleep(for: .milliseconds(5))
    }
    guard cancellation.isCancelled else { return .done }
    seen.yield(.cancelled)
    return .failure(.cancelled)
  }
}

private struct CancelHarness {
  let listener = NSXPCListener.anonymous()
  let delegate: AgentListenerDelegate
  let started: AsyncStream<AgentRequest>
  let seen: AsyncStream<Seen>
  private let handler: ParkingHandler

  init() {
    let (started, startedContinuation) = AsyncStream.makeStream(of: AgentRequest.self)
    let (seen, seenContinuation) = AsyncStream.makeStream(of: Seen.self)
    handler = ParkingHandler(
      started: startedContinuation, seen: seenContinuation, released: Flag())
    delegate = AgentListenerDelegate(handler: handler, role: nil)
    listener.delegate = delegate
    listener.resume()
    self.started = started
    self.seen = seen
  }

  func client(deadline: Duration = AgentClient.replyDeadline) -> AgentClient {
    AgentClient(endpoint: listener.endpoint, replyDeadline: deadline)
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

  /// A client that goes away (quits, crashes) leaves nothing of its transfers running.
  @Test func aLostClientCancelsItsTransfers() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    let file = try scratchFile()
    defer { try? file.close() }
    var started = harness.started.makeAsyncIterator()
    var seen = harness.seen.makeAsyncIterator()
    let connection = NSXPCConnection(listenerEndpoint: harness.listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
    connection.resume()
    let proxy = try #require(connection.remoteObjectProxy as? any AgentXPC)

    proxy.send(try JSONEncoder().encode(fetch), id: "lost", file: file) { _ in }
    #expect(await started.next() == fetch)
    connection.invalidate()

    #expect(await seen.next() == .cancelled)
  }

  /// A recording outlives the app that started it: nothing can cancel it.
  @Test func aRecordingCannotBeCancelled() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    var seen = harness.seen.makeAsyncIterator()
    let client = harness.client()
    let call = Task { try await client.send(.startRecording(DeviceID(serial: "S1")), file: nil) }
    #expect(await seen.next() == .notCancellable)
    call.cancel()
    _ = try? await call.value
  }

  /// T3: a metadata call with no reply in time fails as an agent not answering, which
  /// FileProvider retries, instead of waiting for its own watchdog.
  @Test func anOverdueMetadataCallFailsAsNotResponding() async throws {
    let harness = CancelHarness()
    defer { harness.finish() }
    let client = harness.client(deadline: .milliseconds(100))
    await #expect(throws: TransportError.agentNotResponding) {
      try await client.send(.list(domain: "d", folder: .root), file: nil)
    }
  }

  /// A network connect tries each address with adb's own 30 s limit, in turn: it has no deadline.
  /// Every request with one moves no file contents, so none of them can be cancelled.
  @Test func networkConnectsHaveNoDeadline() throws {
    let id = DeviceID(serial: "S1")
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.31", defaultPort: 5555))
    let connects: [AgentRequest] = [
      .connectAddress(address), .connectWireless(id), .enableWireless(id),
      .confirmWireless(UnconfirmedAddress(address: address, id: id, name: "LinkRunner")),
    ]
    #expect(connects.allSatisfy { $0.mayTakeLong })
    #expect(!AgentRequest.forgetWireless(id).mayTakeLong)
    #expect(!AgentRequest.list(domain: "d", folder: .root).isCancellable)
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
