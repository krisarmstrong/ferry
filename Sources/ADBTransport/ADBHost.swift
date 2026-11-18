import Foundation
import os

/// 1 s doubling to a 30 s ceiling: a server that is slow to come up is retried soon, one that
/// stays down is not hammered.
struct Backoff: Sendable {
  private let initial: Duration
  private let maximum: Duration
  private var current: Duration

  init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
    self.initial = initial
    self.maximum = maximum
    self.current = initial
  }

  mutating func next() -> Duration {
    defer { current = min(current * 2, maximum) }
    return current
  }

  mutating func reset() { current = initial }
}

/// Client for the adb server's host protocol (`127.0.0.1:5037`). Every query is its own
/// connection, as the server expects; `connect` hands its connection over as an `ADBStream`.
public actor ADBHost {
  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBHost")

  private let port: UInt16
  private let locator: ADBLocator
  private let launcher: @Sendable (URL) async throws(ADBError) -> Void
  private let backoff: Backoff

  public init(port: UInt16 = 5037, locator: ADBLocator) {
    self.init(
      port: port, locator: locator,
      launcher: { (adb) async throws(ADBError) in try await Self.startServer(adb: adb, port: port)
      },
      backoff: Backoff())
  }

  init(
    port: UInt16, locator: ADBLocator,
    launcher: @escaping @Sendable (URL) async throws(ADBError) -> Void, backoff: Backoff
  ) {
    self.port = port
    self.locator = locator
    self.launcher = launcher
    self.backoff = backoff
  }

  public func version() async throws(ADBError) -> Int {
    let reply = try await query("host:version")
    guard let version = Int(reply, radix: 16) else {
      throw .protocolViolation("version \(reply) is not hex")
    }
    return version
  }

  public func devices() async throws(ADBError) -> [ADBDevice] {
    ADBWire.devices(from: try await query("host:devices-l"))
  }

  /// A new list for every change the server reports. The stream finishes when the server closes
  /// the connection or answers with an error, and never throws; only a missing server is retried,
  /// starting it once per outage and then backing off.
  public nonisolated func trackDevices() -> AsyncStream<[ADBDevice]> {
    AsyncStream { continuation in
      let task = Task { await self.track(into: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func features(_ serial: String) async throws(ADBError) -> Set<String> {
    do {
      let reply = try await query("host-serial:\(serial):features")
      return Set(reply.split(separator: ",").map(String.init))
    } catch .failed(let message) where message.contains("not found") {
      throw .deviceGone(serial)
    }
  }

  /// Opens a connection routed to `serial` and starts `service` on it; what follows on the
  /// returned stream is the service's own protocol.
  public func connect(_ serial: String, service: String) async throws(ADBError) -> ADBStream {
    let stream = try await ADBStream.open(port: port)
    do throws(ADBError) {
      try await stream.send(request: "host:transport:\(serial)")
      try await stream.expectOkay()
      try await stream.send(request: service)
      try await stream.expectOkay()
      return stream
    } catch {
      await stream.close()
      if case .failed(let message) = error, message.contains("not found") {
        throw .deviceGone(serial)
      }
      throw error
    }
  }

  public func startServer() async throws(ADBError) {
    guard let adb = locator.adbURL() else { throw .adbNotInstalled }
    try await launcher(adb)
  }

  private func query(_ request: String) async throws(ADBError) -> String {
    let stream = try await ADBStream.open(port: port)
    do throws(ADBError) {
      try await stream.send(request: request)
      try await stream.expectOkay()
      let reply = try await stream.readFrame()
      await stream.close()
      return reply
    } catch {
      await stream.close()
      throw error
    }
  }

  private func track(into continuation: AsyncStream<[ADBDevice]>.Continuation) async {
    var backoff = backoff
    var startedThisOutage = false
    while !Task.isCancelled {
      do throws(ADBError) {
        let stream = try await ADBStream.open(port: port)
        await follow(stream, into: continuation)
        break
      } catch {
        if !startedThisOutage {
          startedThisOutage = true
          do throws(ADBError) {
            try await startServer()
            continue
          } catch {
            Self.log.error("adb server not started: \(String(describing: error), privacy: .public)")
          }
        }
        let delay = backoff.next()
        Self.log.info("adb server unavailable; retrying in \(delay.components.seconds)s")
        if (try? await Task.sleep(for: delay)) == nil { break }
      }
    }
    continuation.finish()
  }

  /// Emits each frame until the socket closes or the consumer cancels.
  private func follow(
    _ stream: ADBStream, into continuation: AsyncStream<[ADBDevice]>.Continuation
  ) async {
    await withTaskCancellationHandler {
      do throws(ADBError) {
        try await stream.send(request: "host:track-devices-l")
        try await stream.expectOkay()
        while true {
          continuation.yield(ADBWire.devices(from: try await stream.readFrame()))
        }
      } catch {
        if !Task.isCancelled {
          Self.log.info("device tracking ended: \(String(describing: error), privacy: .public)")
        }
      }
    } onCancel: {
      stream.cancel()
    }
  }

  private static func startServer(adb: URL, port: UInt16) async throws(ADBError) {
    let process = Process()
    process.executableURL = adb
    process.arguments = (port == 5037 ? [] : ["-P", String(port)]) + ["start-server"]
    // The server daemonises and would keep a pipe open, so nothing is captured.
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let status: Result<Int32, ADBError> = await withCheckedContinuation { continuation in
      process.terminationHandler = {
        continuation.resume(returning: .success($0.terminationStatus))
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(
          returning: .failure(.failed("could not run adb: \(error.localizedDescription)")))
      }
    }
    let code = try status.get()
    guard code == 0 else { throw .failed("adb start-server exited with status \(code)") }
  }
}
