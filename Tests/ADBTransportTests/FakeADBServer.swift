import Foundation
import Network
import os

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

  private struct Lifecycle {
    var cancelled = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let listener: NWListener
  private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())
  let port: UInt16

  /// Listens on `port`, or on a free one. `script` runs once per connection; errors in it end
  /// that connection, which is how a test sees a client hang up.
  ///
  /// A free port is picked outside the kernel's ephemeral range (49152 and up), as the real
  /// server's 5037 is, and never one `ClosedPort` picks (20000 to 29999). An OS-assigned port
  /// comes from the ephemeral range, which every outgoing connection's local port comes from
  /// too, and that made a rare connect fail for 10 s under parallel runs: a listener on port A
  /// that closed a connection first leaves its socket A ↔ B in TIME_WAIT for 30 s; the OS then
  /// gives B to another fake listener; a client of that one may be given local port A, which
  /// makes the very same pair, so the connect fails with EADDRINUSE, and the kernel offers the
  /// same local port for that destination again on every new attempt until the TIME_WAIT ends.
  /// Off the ephemeral range, a listener's port is never any client's local port. The bind takes
  /// no address reuse, so it fails while any socket still holds the port, and another is picked.
  static func start(
    port: UInt16? = nil, script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> FakeADBServer {
    if let port {
      // Rebinding a port the test had (a server restart): its own TIME_WAIT sockets may hold it.
      guard let server = try await listen(on: port, reuse: true, script: script) else {
        throw POSIXError(.EADDRINUSE)
      }
      return server
    }
    for _ in 0..<1000 {
      let candidate = UInt16.random(in: 30_000..<40_000)
      if let server = try await listen(on: candidate, reuse: false, script: script) {
        return server
      }
    }
    throw POSIXError(.EADDRINUSE)
  }

  /// Listens on `port`; `nil` if something else holds it.
  private static func listen(
    on port: UInt16, reuse: Bool, script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> FakeADBServer? {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = reuse
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
    let listener = try NWListener(using: parameters)
    // `.ready` has been seen to precede the listening socket accepting connections: a client
    // that connected at once was refused. One probe connection, swallowed here, proves it is.
    let probes = OSAllocatedUnfairLock(initialState: 1)
    listener.newConnectionHandler = { connection in
      if probes.withLock({ remaining in
        defer { remaining = max(remaining - 1, -1) }
        return remaining > 0
      }) {
        connection.cancel()
        return
      }
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
        let server = FakeADBServer(listener: listener, port: listener.port?.rawValue ?? 0)
        listener.stateUpdateHandler = { [weak server] state in
          if case .cancelled = state { server?.markCancelled() }
        }
        try await server.awaitAccepting(probes: probes)
        return server
      case .waiting(.posix(.EADDRINUSE)), .failed(.posix(.EADDRINUSE)):
        listener.stateUpdateHandler = nil
        listener.cancel()
        return nil
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

  /// Connects to the port until it accepts, and waits for the listener to see that probe.
  private func awaitAccepting(probes: OSAllocatedUnfairLock<Int>) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if Self.connects(to: port) {
        while probes.withLock({ $0 }) > 0, ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(5))
        }
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw POSIXError(.ETIMEDOUT)
  }

  private static func connects(to port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    address.sin_port = port.bigEndian
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  func stop() { listener.cancel() }

  /// Cancels the listener and returns once its port is released, so a test can bind the same
  /// port again at once instead of racing the asynchronous cancel. Safe after `stop()` and when
  /// called twice: the cancelled state is recorded, not just observed once.
  func stopAndWait() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      let alreadyCancelled = lifecycle.withLock { state -> Bool in
        if state.cancelled { return true }
        state.waiters.append(done)
        return false
      }
      if alreadyCancelled {
        done.resume()
      } else {
        listener.cancel()
      }
    }
  }

  private func markCancelled() {
    let waiters = lifecycle.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.cancelled = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}
