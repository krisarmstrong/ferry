import Foundation
import Network

@testable import ADBTransport

/// An in-process stand-in for the adb server: a loopback TCP listener that hands each accepted
/// connection to a script. Tests never touch the real server or a device.
final class FakeADBServer: Sendable {
  /// One accepted connection, as the server end of the host protocol.
  struct Peer {
    let stream: ADBStream

    /// Reads one framed request and returns its payload.
    func request() async throws -> String {
      let length = try ADBWire.length(of: await stream.read(exactly: 4))
      return try ADBWire.text(try await stream.read(exactly: length))
    }

    func okay() async throws { try await stream.write(Data("OKAY".utf8)) }

    /// `OKAY` followed by a length-prefixed payload, the reply to a query.
    func answer(_ payload: String) async throws {
      try await stream.write(Data("OKAY".utf8) + ADBWire.frame(payload))
    }

    func fail(_ message: String) async throws {
      try await stream.write(Data("FAIL".utf8) + ADBWire.frame(message))
    }

    func send(_ text: String) async throws { try await stream.write(Data(text.utf8)) }
    func close() async { await stream.close() }
  }

  private let listener: NWListener
  let port: UInt16

  /// Listens on `port`, or on a free one. `script` runs once per connection; errors in it end
  /// that connection, which is how a test sees a client hang up.
  static func start(
    port: UInt16? = nil, script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> FakeADBServer {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      let peer = Peer(stream: ADBStream(connection: connection))
      Task {
        try? await script(peer)
        await peer.close()
      }
    }
    let states = AsyncStream<NWListener.State> { continuation in
      listener.stateUpdateHandler = { continuation.yield($0) }
    }
    listener.start(queue: .global())
    for await state in states {
      switch state {
      case .ready:
        return FakeADBServer(listener: listener, port: listener.port?.rawValue ?? 0)
      case .failed(let error):
        throw error
      default:
        continue
      }
    }
    throw CancellationError()
  }

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
  }

  func stop() { listener.cancel() }

  /// Cancels the listener and returns once its port is released, so a test can bind the same
  /// port again at once instead of racing the asynchronous cancel.
  func stopAndWait() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      listener.stateUpdateHandler = { state in
        if case .cancelled = state { done.resume() }
      }
      listener.cancel()
    }
  }
}
