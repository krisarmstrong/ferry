import Foundation
import Network

/// One TCP connection to the adb server. After the host handshake it is the raw byte pipe of the
/// service that was selected (sync, shell, a log stream), which is why reads are by exact length.
public actor ADBStream {
  nonisolated let connection: NWConnection

  init(connection: NWConnection) {
    self.connection = connection
  }

  /// Connects to the server on loopback. A refused connection is a server that is not running.
  static func open(port: UInt16) async throws(ADBError) -> ADBStream {
    guard let port = NWEndpoint.Port(rawValue: port) else {
      throw .protocolViolation("port 0 is not connectable")
    }
    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    let states = AsyncStream<NWConnection.State> { continuation in
      connection.stateUpdateHandler = { continuation.yield($0) }
    }
    let result: Result<ADBStream, ADBError> = await withTaskCancellationHandler {
      connection.start(queue: .global())
      for await state in states {
        switch state {
        case .ready:
          connection.stateUpdateHandler = nil
          return .success(ADBStream(connection: connection))
        case .waiting, .failed, .cancelled:
          // A refused connect parks in `waiting` and retries; the answer is already known.
          connection.cancel()
          return .failure(.serverUnavailable)
        default:
          continue
        }
      }
      connection.cancel()
      return .failure(.serverUnavailable)
    } onCancel: {
      connection.cancel()
    }
    return try result.get()
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

  private static func received(
    _ chunk: Data?, isComplete: Bool, error: NWError?
  ) -> Result<Data, ADBError> {
    if let error { return .failure(.failed(error.localizedDescription)) }
    if let chunk, !chunk.isEmpty { return .success(chunk) }
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
