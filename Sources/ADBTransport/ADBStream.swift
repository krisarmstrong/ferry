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

  /// Connects to the server on loopback. A refused connection is a server that is not running.
  static func open(port: UInt16, timeout: Duration = .seconds(10)) async throws(ADBError)
    -> ADBStream
  {
    guard let port = NWEndpoint.Port(rawValue: port) else {
      throw .protocolViolation("port 0 is not connectable")
    }
    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    let states = AsyncStream<NWConnection.State> { continuation in
      connection.stateUpdateHandler = { continuation.yield($0) }
    }
    let failure = await withTaskCancellationHandler {
      connection.start(queue: .global())
      return await settle(states, timeout: timeout)
    } onCancel: {
      connection.cancel()
    }
    if let failure {
      connection.cancel()
      throw failure
    }
    connection.stateUpdateHandler = nil
    return ADBStream(connection: connection)
  }

  /// Follows a connection's states until it is ready (`nil`) or has failed. Only a refusal means
  /// no server: Network.framework also waits out transient conditions (an interface coming up),
  /// which may yet connect, so any other wait runs on until `timeout`.
  static func settle(_ states: AsyncStream<NWConnection.State>, timeout: Duration) async
    -> ADBError?
  {
    await withTaskGroup(of: ADBError?.self) { group in
      group.addTask {
        for await state in states {
          switch state {
          case .ready:
            return nil
          case .waiting(let error), .failed(let error):
            if case .posix(.ECONNREFUSED) = error { return .serverUnavailable }
            if case .failed = state { return .failed("connecting to the adb server: \(error)") }
            log.debug("waiting for the adb server: \(String(describing: error), privacy: .public)")
          case .cancelled:
            return .cancelled
          default:
            continue
          }
        }
        return .cancelled
      }
      group.addTask {
        guard (try? await Task.sleep(for: timeout)) != nil else { return .cancelled }
        return .failed("the adb server did not answer in time")
      }
      let first = await group.next() ?? .cancelled
      group.cancelAll()
      return first
    }
  }

  /// Reads exactly `count` bytes, or throws if the peer closes first.
  public func read(exactly count: Int) async throws(ADBError) -> Data {
    var data = Data()
    while data.count < count {
      let remaining = count - data.count
      let result: Result<Data, ADBError> = await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
          continuation.resume(returning: Self.received($0, isComplete: $2, error: $3))
        }
      }
      data.append(try result.get())
    }
    return data
  }

  /// Whatever the peer sends next (at most `count` bytes), or nil once it has closed cleanly.
  func readSome(upTo count: Int) async throws(ADBError) -> Data? {
    let result: Result<Data, ADBError> = await withCheckedContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: count) {
        continuation.resume(returning: Self.received($0, isComplete: $2, error: $3))
      }
    }
    do {
      return try result.get()
    } catch .connectionClosed {
      return nil
    }
  }

  private static func received(
    _ chunk: Data?, isComplete: Bool, error: NWError?
  ) -> Result<Data, ADBError> {
    // Data that arrived with the end of the stream or an error is still data.
    if let chunk, !chunk.isEmpty { return .success(chunk) }
    // Network.framework reports the peer's orderly FIN as ENODATA when data was in flight.
    if case .posix(.ENODATA) = error { return .failure(.connectionClosed) }
    if let error { return .failure(.failed(error.localizedDescription)) }
    // With minimumIncompleteLength 1 a receive carries data, an error or the end of the stream.
    return isComplete
      ? .failure(.connectionClosed) : .failure(.protocolViolation("receive returned nothing"))
  }

  public func write(_ data: Data) async throws(ADBError) {
    let error: NWError? = await withCheckedContinuation { continuation in
      connection.send(
        content: data, completion: .contentProcessed { continuation.resume(returning: $0) })
    }
    if let error { throw .failed(error.localizedDescription) }
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

  /// One length-prefixed payload.
  func readFrame() async throws(ADBError) -> String {
    let length = try ADBWire.length(of: try await read(exactly: 4))
    return try ADBWire.text(try await read(exactly: length))
  }
}
