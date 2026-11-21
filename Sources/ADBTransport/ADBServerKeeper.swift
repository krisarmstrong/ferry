import Darwin
import Foundation
import os

/// The adb server the agent started: its PID, when it started (microseconds since 1970) and its
/// program. A process matching all three is that server, still running.
public struct ADBServerRecord: Codable, Sendable, Equatable {
  public let pid: Int32
  public let started: UInt64
  public let path: String

  public init(pid: Int32, started: UInt64, path: String) {
    self.pid = pid
    self.started = started
    self.path = path
  }

  static func load(_ file: URL) -> ADBServerRecord? {
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
  }

  func save(to file: URL) throws {
    try JSONEncoder().encode(self).write(to: file, options: .atomic)
  }
}

/// Runs the agent's adb server as a child: `adb -L tcp:<port> server nodaemon` (adb's own
/// help: "--one-device … only allowed with 'start-server' or 'server nodaemon'"; AOSP
/// client/commandline.cpp runs `nodaemon` in the foreground, and only `fork-server` calls
/// `setsid`). It stays in the agent's process group, so launchd ends it with the agent.
///
/// The server `adb start-server` forks instead outlives the agent, and macOS keeps holding its
/// network traffic to the agent that started it. Once that agent has exited macOS cannot name
/// it, and denies the server the local network: `adb connect` fails with "No route to host".
///
/// A server already answering is used as it is, unless it is one this keeper recorded starting
/// (same PID, start time and program): an earlier agent's, left running. That one is replaced
/// once, at agent start. A server whose start was never recorded is replaced only when it runs
/// Ferry's own fetched adb and is shown to be cut off (see `replaceFerryServer`).
public actor ADBServerKeeper {
  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBServer")

  let port: UInt16
  let record: URL
  private let spawner: any ADBServerSpawner
  private let table: any ProcessTable
  private let answers: @Sendable () async -> Bool
  private let kill: @Sendable () async -> Void
  private let limit: Duration
  private let poll: Duration
  /// The server this agent started, while it may be running.
  private var child: pid_t?
  private var replacedFerryServer = false
  /// A start under way: both trackers start the server after an outage, and must share it.
  private var starting: Task<Result<Void, ADBError>, Never>?
  /// adb client commands running now (`whileServing`), which a replacement waits out.
  private var commands = 0
  /// A replacement is stopping the server: no command starts until it is done.
  private var replacing = false
  private var waitingCommands: [CheckedContinuation<Void, Never>] = []
  private var waitingReplacement: CheckedContinuation<Void, Never>?

  /// `record` is where the server's start is kept, in the agent's own folder.
  public init(port: UInt16 = 5037, record: URL) {
    let host = ADBHost(
      port: port, locator: ADBLocator(), launcher: { _ in }, backoff: Backoff())
    self.init(
      port: port, record: record, spawner: SystemServerSpawner(), table: SystemProcessTable(),
      answers: { (try? await host.version()) != nil },
      kill: { try? await host.kill() })
  }

  init(
    port: UInt16, record: URL, spawner: any ADBServerSpawner, table: any ProcessTable,
    answers: @escaping @Sendable () async -> Bool, kill: @escaping @Sendable () async -> Void,
    limit: Duration = .seconds(10), poll: Duration = .milliseconds(100)
  ) {
    self.port = port
    self.record = record
    self.spawner = spawner
    self.table = table
    self.answers = answers
    self.kill = kill
    self.limit = limit
    self.poll = poll
  }

  /// `adb.json` beside the agent's other state.
  public static func defaultRecord() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "io.github.krisarmstrong.ferry.agent/adb-server.json")
  }

  /// Starts a server unless one answers, and returns once it answers. A start already under way
  /// is waited for, not repeated.
  func start(_ adb: URL) async throws(ADBError) {
    if let starting { return try await starting.value.get() }
    let task = Task { await self.launch(adb) }
    starting = task
    let result = await task.value
    starting = nil
    try result.get()
  }

  private func launch(_ adb: URL) async -> Result<Void, ADBError> {
    do throws(ADBError) {
      try await spawnAndWait(adb)
      return .success(())
    } catch {
      return .failure(error)
    }
  }

  private func spawnAndWait(_ adb: URL) async throws(ADBError) {
    if await answers() { return }
    let pid = try spawner.spawn(adb, arguments: ["-L", "tcp:\(port)", "server", "nodaemon"])
    child = pid
    if let started = table.started(pid) {
      do {
        try ADBServerRecord(pid: pid, started: started, path: adb.path).save(to: record)
      } catch {
        Self.log.error("recording the adb server failed: \(error, privacy: .public)")
      }
    }
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if await answers() { return }
      // Another server took the port first: it answers, and this one has nothing to serve.
      if spawner.hasExited(pid) {
        child = nil
        if await answers() { return }
        throw .failed("the adb server exited at start")
      }
      try? await Task.sleep(for: poll)
    }
    throw .failed("the adb server did not answer in time")
  }

  /// Runs an adb client command that checked for a server and then uses it. A client finding no
  /// server forks a daemon of its own, which outlives the agent and is cut off when it exits, so
  /// a replacement never stops the server under a command, and no command starts during one.
  public func whileServing<T: Sendable>(
    _ body: @Sendable () async throws(ADBError) -> T
  ) async throws(ADBError) -> T {
    while replacing {
      await withCheckedContinuation { waitingCommands.append($0) }
    }
    commands += 1
    let result: Result<T, ADBError>
    do throws(ADBError) {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    commands -= 1
    if commands == 0, let waiting = waitingReplacement {
      waitingReplacement = nil
      waiting.resume()
    }
    return try result.get()
  }

  /// Stops the server once no command is using it, holding new commands back meanwhile, if
  /// `isTheOne` still holds then: the port may have changed hands during the wait. Returns
  /// whether it stopped it.
  private func replace(if isTheOne: () -> Bool) async -> Bool {
    replacing = true
    if commands > 0 {
      await withCheckedContinuation { waitingReplacement = $0 }
    }
    let stopping = isTheOne()
    if stopping { await stop() }
    replacing = false
    let waiting = waitingCommands
    waitingCommands = []
    for command in waiting { command.resume() }
    return stopping
  }

  /// At agent start: replaces the server an earlier agent recorded, if it is still the one
  /// answering. Returns whether it did.
  @discardableResult
  public func replaceRecordedOrphan() async -> Bool {
    guard let recorded = ADBServerRecord.load(record), recorded.pid != child else { return false }
    // The recorded process, still running, and the one holding the port `host:kill` reaches.
    let isRecorded = { [table, port] in
      table.listener(onTCPPort: port) == recorded.pid
        && table.started(recorded.pid) == recorded.started
        && table.path(recorded.pid) == recorded.path
    }
    guard isRecorded() else { return false }
    Self.log.notice("replacing the adb server an earlier agent started (\(recorded.pid))")
    guard await replace(if: isRecorded) else { return false }
    try? FileManager.default.removeItem(at: record)
    return true
  }

  /// For a server no record names: one Ferry's agent started before it kept records outlives
  /// that agent and is cut off from the network in the same way. When adb finds no route to an
  /// address the agent itself reaches, the server listening on the port is replaced if its
  /// program, resolved, is `fetched` (Ferry's current fetched adb, signature-checked on disk)
  /// and the code it runs is Google's adb. A server running an older fetched version, Homebrew's
  /// or Android Studio's is left alone. Once per agent. Returns whether it did.
  public func replaceFerryServer(fetched: URL?) async -> Bool {
    guard !replacedFerryServer, let fetched, let pid = table.listener(onTCPPort: port),
      pid != child
    else { return false }
    let program = fetched.resolvingSymlinksInPath().path
    let isFerrys = { [table, port] in
      table.listener(onTCPPort: port) == pid && table.path(pid) == program
        && table.runsGoogleADB(pid)
    }
    guard isFerrys() else { return false }
    replacedFerryServer = true
    Self.log.notice("replacing an adb server cut off from the network (\(pid))")
    return await replace(if: isFerrys)
  }

  /// `host:kill`, then waits for the port to fall silent so the next start does not find it.
  private func stop() async {
    await kill()
    let deadline = ContinuousClock.now + limit
    while await answers(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: poll)
    }
  }
}
