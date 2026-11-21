import Foundation
import Network
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBStream")

/// One TCP connection to the adb server. After the host handshake it is the raw byte pipe of the
/// service that was selected (sync, shell, a log stream), which is why reads are by exact length.
public actor ADBStream {
  nonisolated let connection: NWConnection

  init(connection: NWConnection) {
    self.connection = connection
  }

  /// A stream dropped without `close()` (a sync connection let go after a cancelled request, a
  /// log stream whose reader went away) still closes its socket.
  deinit {
    connection.cancel()
  }

  /// Connects to the server on loopback. A refused connection is a server that is not running.
  static func open(port: UInt16, timeout: Duration = .seconds(10)) async throws(ADBError)
    -> ADBStream
  {
    guard let port = NWEndpoint.Port(rawValue: port) else {
      throw .protocolViolation("port 0 is not connectable")
    }
    let clock = ContinuousClock()
    let connection = try await connect(until: clock.now + timeout, on: clock) {
      let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
      let states = AsyncStream<NWConnection.State> { continuation in
        connection.stateUpdateHandler = { continuation.yield($0) }
      }
      return Attempt(
        value: connection, states: states, start: { connection.start(queue: .global()) },
        cancel: { connection.cancel() })
    }
    connection.stateUpdateHandler = nil
    return ADBStream(connection: connection)
  }

  /// One connection attempt, as `connect` drives it.
  struct Attempt<Value: Sendable>: Sendable {
    let value: Value
    let states: AsyncStream<NWConnection.State>
    let start: @Sendable () -> Void
    let cancel: @Sendable () -> Void
  }

  /// Makes attempts until one is ready (its value is returned), one fails, or `deadline`
  /// passes on `clock`. A stalled attempt is cancelled and replaced: a new connection gets a new
  /// local port, where retrying the stalled one would not.
  static func connect<Value: Sendable, C: Clock<Duration>>(
    until deadline: C.Instant, on clock: C, _ attempt: () -> Attempt<Value>
  ) async throws(ADBError) -> Value {
    while true {
      let next = attempt()
      let outcome = await withTaskCancellationHandler {
        next.start()
        return await settle(next.states, until: deadline, on: clock)
      } onCancel: {
        next.cancel()
      }
      if outcome == .ready { return next.value }
      next.cancel()
      if case .failed(let error) = outcome { throw error }
      guard clock.now.advanced(by: retryDelay) < deadline else { throw timedOut }
      guard (try? await clock.sleep(for: retryDelay)) != nil else { throw .cancelled }
    }
  }

  static let retryDelay = Duration.milliseconds(50)
  static let timedOut = ADBError.failed("the adb server did not answer in time")

  enum Settled: Equatable {
    case ready
    /// Waiting for a reason other than a refusal, which may pass on another attempt.
    case stalled
    case failed(ADBError)
  }

  /// Follows a connection's states until it is ready, has failed, or stalls. Only a refusal
  /// means no server. Any other wait may pass, but Network.framework retries a waiting
  /// connection only when the network path changes, which loopback never does, and with the
  /// same local port: a clash there (EADDRINUSE, a loaded machine's many short connections)
  /// would wait forever. So the caller starts over with a new connection.
  static func settle<C: Clock<Duration>>(
    _ states: AsyncStream<NWConnection.State>, until deadline: C.Instant, on clock: C
  ) async -> Settled {
    await withTaskGroup(of: Settled.self) { group in
      group.addTask {
        for await state in states {
          switch state {
          case .ready:
            return .ready
          case .waiting(let error), .failed(let error):
            if case .posix(.ECONNREFUSED) = error { return .failed(.serverUnavailable) }
            if case .failed = state {
              return .failed(.failed("connecting to the adb server: \(error)"))
            }
            log.debug("waiting for the adb server: \(String(describing: error), privacy: .private)")
            return .stalled
          case .cancelled:
            return .failed(.cancelled)
          default:
            continue
          }
        }
        return .failed(.cancelled)
      }
      group.addTask {
        guard (try? await clock.sleep(until: deadline, tolerance: nil)) != nil else {
          return .failed(.cancelled)
        }
        return .failed(timedOut)
      }
      let first = await group.next() ?? .failed(.cancelled)
      group.cancelAll()
      return first
    }
  }

  /// Reads exactly `count` bytes, or throws if the peer closes first.
  public func read(exactly count: Int) async throws(ADBError) -> Data {
    var data = Data()
    while data.count < count {
      data.append(try await receive(upTo: count - data.count).get())
    }
    return data
  }

  /// Whatever the peer sends next (at most `count` bytes), or nil once it has closed cleanly.
  func readSome(upTo count: Int) async throws(ADBError) -> Data? {
    do {
      return try await receive(upTo: count).get()
    } catch .connectionClosed {
      return nil
    }
  }

  /// One receive. A cancelled task closes the connection, which ends a receive the peer would
  /// never answer (a wedged device), and gets `.cancelled`.
  private func receive(upTo count: Int) async throws(ADBError) -> Result<Data, ADBError> {
    let result: Result<Data, ADBError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: count) {
          continuation.resume(returning: Self.received($0, isComplete: $2, error: $3))
        }
      }
    } onCancel: { [connection] in
      connection.cancel()
    }
    if case .failure = result, Task.isCancelled { throw .cancelled }
    return result
  }

  static func received(
    _ chunk: Data?, isComplete: Bool, error: NWError?
  ) -> Result<Data, ADBError> {
    // Data that arrived with the end of the stream or an error is still data.
    if let chunk, !chunk.isEmpty { return .success(chunk) }
    if let error { return .failure(failure(error)) }
    // With minimumIncompleteLength 1 a receive carries data, an error or the end of the stream.
    return isComplete
      ? .failure(.connectionClosed) : .failure(.protocolViolation("receive returned nothing"))
  }

  public func write(_ data: Data) async throws(ADBError) {
    let error: NWError? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        connection.send(
          content: data, completion: .contentProcessed { continuation.resume(returning: $0) })
      }
    } onCancel: { [connection] in
      connection.cancel()
    }
    if let error { throw Task.isCancelled ? .cancelled : Self.failure(error) }
  }

  /// A peer that went away is a closed connection, however the socket says so: Network.framework
  /// reports an orderly FIN as ENODATA when data was in flight, and a server that died as a reset
  /// or a broken pipe.
  private static func failure(_ error: NWError) -> ADBError {
    switch error {
    case .posix(.ENODATA), .posix(.ECONNRESET), .posix(.EPIPE): .connectionClosed
    default: .failed(error.localizedDescription)
    }
  }

  public func close() {
    connection.cancel()
  }

  /// Closes the socket without waiting for the actor, so a read blocked on it fails at once.
  nonisolated func cancel() {
    connection.cancel()
  }

  /// Reads the server's `OKAY`, or turns `FAIL<len><message>` into `.failed(message)`.
  func expectOkay() async throws(ADBError) {
    let status = try await read(exactly: 4)
    switch try ADBWire.text(status) {
    case "OKAY":
      return
    case "FAIL":
      throw .failed(try await readFrame())
    case let other:
      throw .protocolViolation("unexpected status \(other)")
    }
  }

  /// A host service's answer: one length-prefixed reply after its `OKAY`, or `FAIL` and the
  /// server's reason, returned as its refusal, so only a lost or wedged connection is thrown. A
  /// service the server runs on a thread of its own (`connect:`, `pair:`) is acknowledged with
  /// `OKAY` as soon as it starts, so its own `FAIL` follows that `OKAY` (AOSP
  /// packages/modules/adb 1cf2f017, sockets.cpp:894, services.cpp:155). `FAIL` is never a
  /// length: its letters are not all hex digits.
  func readServiceAnswer() async throws(ADBError) -> ADBServiceAnswer {
    let fail = Data("FAIL".utf8)
    let status = try await read(exactly: 4)
    if status == fail { return .refused(try await readFrame()) }
    guard status == Data("OKAY".utf8) else {
      throw .protocolViolation("unexpected status \(try ADBWire.text(status))")
    }
    let head = try await read(exactly: 4)
    if head == fail { return .refused(try await readFrame()) }
    return .reply(try ADBWire.text(try await read(exactly: ADBWire.length(of: head))))
  }

  /// One length-prefixed payload.
  func readFrame() async throws(ADBError) -> String {
    let length = try ADBWire.length(of: try await read(exactly: 4))
    return try ADBWire.text(try await read(exactly: length))
  }
}
