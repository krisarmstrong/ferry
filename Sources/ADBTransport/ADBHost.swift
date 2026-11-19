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

/// What device tracking reports: a list, or that the server went away.
public enum ADBServerEvent: Sendable, Equatable {
  case devices([ADBDevice])
  case unavailable
}

/// Client for the adb server's host protocol (`127.0.0.1:5037`). Every query is its own
/// connection, as the server expects; `connect` hands its connection over as an `ADBStream`.
public actor ADBHost {
  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBHost")

  let port: UInt16
  private let locator: ADBLocator
  private let launcher: @Sendable (URL) async throws(ADBError) -> Void
  private let backoff: Backoff
  /// adb serials pinned to the server's connection to one unit (`transport_id`), while a
  /// session is open on it. adb reconnects a network address by itself, and the unit answering
  /// there afterwards may be another one: a pinned serial is selected by its connection, so
  /// whatever reaches it (the session's new sync connections, its commands, the tools) fails
  /// once that connection is gone rather than reaching the other unit.
  private var pins: [String: String] = [:]

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

  /// The `adb` program the locator finds, if any.
  public nonisolated func adbURL() -> URL? {
    locator.adbURL()
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

  /// A new list for every change the server reports, and `[]` once when the server goes away.
  /// It reconnects on its own and finishes only when the consumer stops iterating.
  public nonisolated func trackDevices() -> AsyncStream<[ADBDevice]> {
    // Each list replaces the last, so a slow consumer needs only the newest.
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        await self.track { event in
          switch event {
          case .devices(let devices): continuation.yield(devices)
          case .unavailable: continuation.yield([])
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// As `trackDevices()`, but says when the server went away rather than reporting no devices,
  /// for a consumer that must act when the server comes back (it drops network connections).
  /// Nothing is coalesced, so a slow consumer still sees every outage; events come only when adb
  /// reports a change, so the buffer stays small.
  public nonisolated func trackServer() -> AsyncStream<ADBServerEvent> {
    AsyncStream(bufferingPolicy: .unbounded) { continuation in
      let task = Task {
        await self.track { continuation.yield($0) }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Selects `serial`'s connection by its transport id from now on (see `pins`).
  func pin(_ serial: String, to transportID: String) {
    pins[serial] = transportID
  }

  /// Ends a pin, unless another session has pinned the serial since.
  func unpin(_ serial: String, from transportID: String) {
    if pins[serial] == transportID { pins[serial] = nil }
  }

  /// The serial's connection to select by: `transportID` when the caller names one (a scan
  /// reading the connection it listed), else the pin, if any.
  private func selected(_ serial: String, _ transportID: String?) -> String? {
    transportID ?? pins[serial]
  }

  public func features(_ serial: String, transportID: String? = nil) async throws(ADBError)
    -> Set<String>
  {
    let prefix =
      selected(serial, transportID).map { "host-transport-id:\($0)" } ?? "host-serial:\(serial)"
    do {
      let reply = try await query("\(prefix):features")
      return Set(reply.split(separator: ",").map(String.init))
    } catch .failed(let message) where Self.isGone(message) {
      throw .deviceGone(serial)
    }
  }

  /// adb's words for a serial it does not list, or a transport id it no longer has.
  private static func isGone(_ message: String) -> Bool {
    message.contains("not found") || message.hasPrefix("no device with transport id")
  }

  /// Opens a connection routed to `serial` (by its pinned connection, if it has one) and starts
  /// `service` on it; what follows on the returned stream is the service's own protocol.
  public func connect(
    _ serial: String, service: String, transportID: String? = nil
  ) async throws(ADBError) -> ADBStream {
    let target =
      selected(serial, transportID).map { "host:transport-id:\($0)" }
      ?? "host:transport:\(serial)"
    let select = try ADBWire.frame(target)
    let start = try ADBWire.frame(service)
    let stream = try await ADBStream.open(port: port)
    do throws(ADBError) {
      try await stream.write(select)
      try await stream.expectOkay()
      try await stream.write(start)
      try await stream.expectOkay()
      return stream
    } catch {
      await stream.close()
      if case .failed(let message) = error, Self.isGone(message) {
        throw .deviceGone(serial)
      }
      throw error
    }
  }

  public func startServer() async throws(ADBError) {
    guard let adb = locator.adbURL() else { throw .adbNotInstalled }
    try await launcher(adb)
  }

  func query(_ request: String) async throws(ADBError) -> String {
    let framed = try ADBWire.frame(request)
    let stream = try await ADBStream.open(port: port)
    do throws(ADBError) {
      try await stream.write(framed)
      try await stream.expectOkay()
      let reply = try await stream.readFrame()
      await stream.close()
      return reply
    } catch {
      await stream.close()
      throw error
    }
  }

  /// Survives server restarts: when the connection closes or the server is missing, reports
  /// no devices once, starts the server at most once per outage, and retries with back-off.
  /// Only the consumer stopping ends it.
  private func track(_ emit: @Sendable (ADBServerEvent) -> Void) async {
    var backoff = backoff
    var reportedGone = false
    var startedThisOutage = false
    while !Task.isCancelled {
      var connected = false
      do throws(ADBError) {
        let stream = try await ADBStream.open(port: port)
        connected = await follow(stream, emit: emit) {
          reportedGone = false
          startedThisOutage = false
          backoff.reset()
        }
      } catch {}
      if Task.isCancelled { break }
      if !reportedGone {
        reportedGone = true
        emit(.unavailable)
      }
      if !connected && !startedThisOutage {
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

  /// Emits each frame until the socket closes or the consumer cancels. `onFrame` runs before
  /// each emission; the result says whether the server was reached (the handshake succeeded).
  private func follow(
    _ stream: ADBStream, emit: @Sendable (ADBServerEvent) -> Void, onFrame: () -> Void
  ) async -> Bool {
    await withTaskCancellationHandler {
      // The server closing, a bad frame or a refused handshake all end up here too.
      defer { stream.cancel() }
      var reached = false
      do throws(ADBError) {
        try await stream.write(ADBWire.frame("host:track-devices-l"))
        try await stream.expectOkay()
        reached = true
        while true {
          let devices = ADBWire.devices(from: try await stream.readFrame())
          onFrame()
          emit(.devices(devices))
        }
      } catch {
        if !Task.isCancelled {
          Self.log.info("device tracking ended: \(String(describing: error), privacy: .public)")
        }
      }
      return reached
    } onCancel: {
      stream.cancel()
    }
  }

  /// Runs `adb start-server`, which returns once the server is up. A cancelled caller stops
  /// waiting at once: adb is terminated (if it was launched) and `.cancelled` thrown.
  static func startServer(adb: URL, port: UInt16) async throws(ADBError) {
    let process = Process()
    process.executableURL = adb
    process.arguments = (port == 5037 ? [] : ["-P", String(port)]) + ["start-server"]
    // The server daemonises and would keep a pipe open, so nothing is captured.
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    // `terminate()` raises on a process not yet launched, so it is sent only after `run()`.
    let launch = OSAllocatedUnfairLock(initialState: (launched: false, cancelled: false))
    let status: Result<Int32, ADBError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        process.terminationHandler = {
          continuation.resume(returning: .success($0.terminationStatus))
        }
        guard !launch.withLock({ $0.cancelled }) else {
          process.terminationHandler = nil
          continuation.resume(returning: .failure(.cancelled))
          return
        }
        do {
          try process.run()
        } catch {
          process.terminationHandler = nil
          continuation.resume(
            returning: .failure(.failed("could not run adb: \(error.localizedDescription)")))
          return
        }
        let cancelled = launch.withLock { state in
          state.launched = true
          return state.cancelled
        }
        if cancelled { process.terminate() }
      }
    } onCancel: {
      let launched = launch.withLock { state in
        state.cancelled = true
        return state.launched
      }
      if launched { process.terminate() }
    }
    let code = try status.get()
    if launch.withLock({ $0.cancelled }) { throw .cancelled }
    guard code == 0 else { throw .failed("adb start-server exited with status \(code)") }
  }
}
