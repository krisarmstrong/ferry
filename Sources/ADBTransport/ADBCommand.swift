import DeviceKit
import Foundation
import os

/// What an `adb` command printed, stdout and stderr together, and its exit status. adb exits 0
/// from `connect` even when it could not connect, so the status is a hint at most.
public struct ADBCommandResult: Sendable, Equatable {
  public let status: Int32
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

/// Runs the user's `adb` with an argument array. Tests pass a fake.
public typealias ADBCommandRunner =
  @Sendable (_ arguments: [String]) async throws(ADBError) -> ADBCommandResult

/// The `adb` commands Ferry runs besides `start-server`, each an argument array built here from
/// validated values, and the one way they are run: `Process` on the located `adb`, never a shell
/// and never a `PATH` lookup.
public enum ADBCommand {
  public static func connect(_ endpoint: WirelessEndpoint) -> [String] {
    ["connect", endpoint.argument]
  }

  public static func disconnect(_ endpoint: WirelessEndpoint) -> [String] {
    ["disconnect", endpoint.argument]
  }

  public static func pair(_ endpoint: WirelessEndpoint, _ code: PairingCode) -> [String] {
    ["pair", endpoint.argument, code.digits]
  }

  /// How long one command may take. `adb connect` gives up on an unreachable host by itself in
  /// about ten seconds; this only stops one that never returns.
  public static let defaultLimit = Duration.seconds(30)
  /// Output beyond this is dropped: Ferry reads one line of it.
  static let outputLimit = 64 * 1024

  /// Runs the `adb` that `locator` finds, against the server on `port`.
  public static func runner(
    locator: ADBLocator = ADBLocator(), port: UInt16 = 5037, limit: Duration = defaultLimit
  ) -> ADBCommandRunner {
    { (arguments) async throws(ADBError) in
      guard let adb = locator.adbURL() else { throw .adbNotInstalled }
      return try await run(adb, Self.arguments(arguments, port: port), limit: limit)
    }
  }

  static func arguments(_ arguments: [String], port: UInt16) -> [String] {
    (port == 5037 ? [] : ["-P", String(port)]) + arguments
  }

  /// Output goes to a private file, not a pipe: a server `adb` starts as a side effect would
  /// inherit a pipe and hold it open long after the command has finished.
  static func run(
    _ executable: URL, _ arguments: [String], limit: Duration
  ) async throws(ADBError) -> ADBCommandResult {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "ferry-adb-\(UUID().uuidString)")
    guard
      FileManager.default.createFile(
        atPath: file.path, contents: nil,
        attributes: [.posixPermissions: 0o600]),
      let output = try? FileHandle(forWritingTo: file)
    else { throw .failed("could not capture adb's output") }
    defer {
      try? output.close()
      try? FileManager.default.removeItem(at: file)
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    let status = try await wait(for: process, limit: limit)
    let data = (try? FileHandle(forReadingFrom: file)).flatMap { reader in
      defer { try? reader.close() }
      return try? reader.read(upToCount: outputLimit)
    }
    return ADBCommandResult(
      status: status, output: data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "")
  }

  /// Runs `process` and waits for it, terminating it when `limit` passes or the caller is
  /// cancelled. A process that has already finished is never reported as stopped: the timer can
  /// fire between its exit and the timer's cancel.
  private static func wait(for process: Process, limit: Duration) async throws(ADBError) -> Int32 {
    let state = OSAllocatedUnfairLock(
      initialState: (launched: false, finished: false, stopped: false))
    let stop: @Sendable () -> Void = {
      let terminate = state.withLock { state -> Bool in
        guard !state.finished else { return false }
        state.stopped = true
        return state.launched
      }
      if terminate { process.terminate() }
    }
    let timer = Task {
      guard (try? await Task.sleep(for: limit)) != nil else { return }
      stop()
    }
    defer { timer.cancel() }
    let result: Result<Int32, ADBError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        process.terminationHandler = { process in
          state.withLock { $0.finished = true }
          continuation.resume(returning: .success(process.terminationStatus))
        }
        do {
          try process.run()
        } catch {
          process.terminationHandler = nil
          continuation.resume(
            returning: .failure(.failed("could not run adb: \(error.localizedDescription)")))
          return
        }
        let stopped = state.withLock { state in
          state.launched = true
          return state.stopped
        }
        if stopped { process.terminate() }
      }
    } onCancel: {
      stop()
    }
    let status = try result.get()
    if state.withLock({ $0.stopped }) {
      throw Task.isCancelled ? .cancelled : .failed("adb did not finish within \(limit)")
    }
    return status
  }
}
