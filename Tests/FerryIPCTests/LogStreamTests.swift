import DeviceKit
import Foundation
import Synchronization
import Testing

@testable import FerryIPC

private let device = DeviceID(serial: "R58N12345")

/// Sends three batches to the client's sink, as the agent streams a log, and answers `.done`;
/// holds the sink so a test can use it after the request has returned.
private final class Streamer: AgentHandling, Sendable {
  private let sink = Mutex<LogSink?>(nil)
  private let answers = Mutex<[Bool]>([])

  var heldSink: LogSink? { sink.withLock { $0 } }
  var sinkAnswers: [Bool] { answers.withLock { $0 } }

  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse {
    .failure(.unsupported("no log sink"))
  }

  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler,
    logs: LogSink?
  ) async -> AgentResponse {
    guard case .startLogcat = request, let logs else { return .failure(.unsupported("no sink")) }
    sink.withLock { $0 = logs }
    for index in 0..<3 {
      let kept = await logs(LogBatch(lines: ["line \(index)a", "line \(index)b"], skipped: index))
      answers.withLock { $0.append(kept) }
    }
    return .done
  }
}

private actor Received {
  private(set) var batches: [LogBatch] = []
  func add(_ batch: LogBatch) { batches.append(batch) }
}

/// An anonymous listener serving `handler`, and a client connected to it.
private struct Served {
  let listener = NSXPCListener.anonymous()
  // The listener does not retain its delegate.
  let delegate: AgentListenerDelegate
  let client: AgentClient

  init(_ handler: some AgentHandling) {
    delegate = AgentListenerDelegate(handler: handler, role: nil)
    listener.delegate = delegate
    listener.resume()
    client = AgentClient(endpoint: listener.endpoint)
  }

  func finish() { listener.invalidate() }
}

@Test func aLogBatchRoundTripsJSON() throws {
  let batch = LogBatch(lines: ["a", "", "é \u{1F600}"], skipped: 3)
  #expect(try JSONDecoder().decode(LogBatch.self, from: JSONEncoder().encode(batch)) == batch)
}

/// Each batch reaches the client's handler, in order, before the reply; the agent's sink says
/// each was taken.
@Test(.timeLimit(.minutes(1)))
func batchesReachTheClientInOrderBeforeTheReply() async throws {
  let streamer = Streamer()
  let served = Served(streamer)
  defer { served.finish() }
  let client = served.client
  let received = Received()
  let response = try await client.send(
    .startLogcat(device, stream: UUID()), file: nil, progress: nil, logs: { await received.add($0) }
  )
  #expect(response == .done)
  let batches = await received.batches
  #expect(
    batches.map(\.lines) == [
      ["line 0a", "line 0b"], ["line 1a", "line 1b"], ["line 2a", "line 2b"],
    ])
  #expect(batches.map(\.skipped) == [0, 1, 2])
  #expect(streamer.sinkAnswers == [true, true, true])
}

/// Once the request has ended on the client, the agent's sink is told to stop: a stream whose
/// client went away (the app quit, the window closed) is not left running.
@Test(.timeLimit(.minutes(1)))
func theSinkSaysStopOnceTheClientsRequestEnded() async throws {
  let streamer = Streamer()
  let served = Served(streamer)
  defer { served.finish() }
  let client = served.client
  _ = try await client.send(
    .startLogcat(device, stream: UUID()), file: nil, progress: nil, logs: { _ in })
  let sink = try #require(streamer.heldSink)
  #expect(await sink(LogBatch(lines: ["late"], skipped: 0)) == false)
}

/// A request sent with no handler for lines gets no stream: the agent's sink says stop at once.
@Test(.timeLimit(.minutes(1)))
func aRequestWithNoHandlerStopsTheStream() async throws {
  let streamer = Streamer()
  let served = Served(streamer)
  defer { served.finish() }
  let client = served.client
  _ = try await client.send(.startLogcat(device, stream: UUID()), file: nil)
  #expect(streamer.sinkAnswers == [false, false, false])
}

/// A batch the client cannot decode is dropped without ending the stream.
@Test func theReceiverDropsABatchItCannotDecode() async {
  let router = LogRouter()
  let received = Received()
  router.set("id") { await received.add($0) }
  #expect(await router.deliver("id", Data("not json".utf8)) == true)
  #expect(await router.deliver("other", Data()) == false)
  let good = try? JSONEncoder().encode(LogBatch(lines: ["x"], skipped: 0))
  #expect(await router.deliver("id", good ?? Data()) == true)
  #expect(await received.batches.map(\.lines) == [["x"]])
  router.remove("id")
  #expect(await router.deliver("id", good ?? Data()) == false)
}
