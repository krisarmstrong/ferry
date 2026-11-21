import Darwin
import Foundation
import Synchronization
import Testing

@testable import ADBTransport

/// The agent's own adb server is its child, recorded so that one a previous agent left behind
/// can be told from one someone else started. Fakes stand in for the process and host layers.
struct ADBServerKeeperTests {
  struct FakeState {
    var answering = false
    var spawned: [(adb: String, arguments: [String])] = []
    var nextPID: pid_t = 4242
    /// Whether a spawned server comes up, or exits at once.
    var serverComesUp = true
    var exited: Set<pid_t> = []
    var started: [pid_t: UInt64] = [:]
    var paths: [pid_t: String] = [:]
    var listener: pid_t?
    var kills = 0
  }

  final class Fakes: Sendable {
    let state = Mutex(FakeState())

    func callAsFunction<T: Sendable>(_ body: (inout FakeState) -> T) -> T {
      state.withLock { body(&$0) }
    }
  }

  struct FakeSpawner: ADBServerSpawner {
    let fakes: Fakes

    func spawn(_ adb: URL, arguments: [String]) throws(ADBError) -> pid_t {
      fakes { state in
        let pid = state.nextPID
        state.spawned.append((adb.path, arguments))
        state.paths[pid] = adb.path
        state.started[pid] = 777
        if state.serverComesUp { state.answering = true } else { state.exited.insert(pid) }
        return pid
      }
    }

    func hasExited(_ pid: pid_t) -> Bool { fakes { $0.exited.contains(pid) } }
  }

  struct FakeTable: ProcessTable {
    let fakes: Fakes

    func started(_ pid: pid_t) -> UInt64? { fakes { $0.started[pid] } }
    func path(_ pid: pid_t) -> String? { fakes { $0.paths[pid] } }
    func listener(onTCPPort port: UInt16) -> pid_t? { fakes { $0.listener } }
  }

  static let adb = URL(
    filePath: "/Users/me/Library/Application Support/Ferry/platform-tools/37/adb")

  static func recordFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ferry-adb-server-\(UUID()).json")
  }

  static func keeper(_ fakes: Fakes, record: URL) -> ADBServerKeeper {
    ADBServerKeeper(
      port: 5037, record: record, spawner: FakeSpawner(fakes: fakes),
      table: FakeTable(fakes: fakes),
      answers: { fakes { $0.answering } },
      kill: {
        fakes { state in
          state.kills += 1
          state.answering = false
        }
      },
      limit: .seconds(2), poll: .milliseconds(10))
  }

  static func outcome(_ body: () async throws(ADBError) -> Void) async -> ADBError? {
    do throws(ADBError) {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  // MARK: Starting

  /// `server nodaemon` keeps the server in the agent's process group, so launchd ends it with
  /// the agent; its PID, start time and program are recorded.
  @Test func startRunsANodaemonServerAndRecordsIt() async throws {
    let fakes = Fakes()
    let record = Self.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try await Self.keeper(fakes, record: record).start(Self.adb)
    #expect(fakes { $0.spawned.map(\.arguments) } == [["-L", "tcp:5037", "server", "nodaemon"]])
    #expect(fakes { $0.spawned.map(\.adb) } == [Self.adb.path])
    #expect(
      ADBServerRecord.load(record) == ADBServerRecord(pid: 4242, started: 777, path: Self.adb.path)
    )
  }

  @Test func aServerThatAnswersIsLeftAlone() async throws {
    let fakes = Fakes()
    fakes { $0.answering = true }
    let record = Self.recordFile()
    try await Self.keeper(fakes, record: record).start(Self.adb)
    #expect(fakes { $0.spawned.isEmpty })
    #expect(ADBServerRecord.load(record) == nil)
  }

  @Test func aServerThatExitsWithoutAnsweringIsAFailure() async throws {
    let fakes = Fakes()
    fakes { $0.serverComesUp = false }
    let record = Self.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    let keeper = Self.keeper(fakes, record: record)
    let error = await Self.outcome { () async throws(ADBError) in try await keeper.start(Self.adb) }
    #expect(error == .failed("the adb server exited at start"))
  }

  // MARK: A server a previous agent left

  @Test func aRecordedServerStillRunningIsReplaced() async throws {
    let fakes = Fakes()
    let record = Self.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try ADBServerRecord(pid: 9, started: 5, path: Self.adb.path).save(to: record)
    fakes { state in
      state.answering = true
      state.started[9] = 5
      state.paths[9] = Self.adb.path
    }
    #expect(await Self.keeper(fakes, record: record).replaceRecordedOrphan())
    #expect(fakes { $0.kills } == 1)
    #expect(ADBServerRecord.load(record) == nil)
  }

  /// The PID was reused, or the server was started by another program: not Ferry's.
  static let mismatches: [(started: UInt64, path: String)] = [
    (6, adb.path), (5, "/opt/homebrew/bin/adb"),
  ]

  @Test(arguments: mismatches)
  func aServerNotMatchingTheRecordIsLeftAlone(started: UInt64, path: String) async throws {
    let fakes = Fakes()
    let record = Self.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try ADBServerRecord(pid: 9, started: 5, path: Self.adb.path).save(to: record)
    fakes { state in
      state.answering = true
      state.started[9] = started
      state.paths[9] = path
    }
    #expect(await Self.keeper(fakes, record: record).replaceRecordedOrphan() == false)
    #expect(fakes { $0.kills } == 0)
  }

  @Test func withNoRecordNothingIsReplaced() async {
    let fakes = Fakes()
    fakes { $0.answering = true }
    #expect(await Self.keeper(fakes, record: Self.recordFile()).replaceRecordedOrphan() == false)
    #expect(fakes { $0.kills } == 0)
  }

  // MARK: A server an agent from before the record left

  @Test func ferrysOwnAdbListeningIsReplacedOnce() async {
    let fakes = Fakes()
    fakes { state in
      state.answering = true
      state.listener = 33
      state.paths[33] = Self.adb.path
    }
    let keeper = Self.keeper(fakes, record: Self.recordFile())
    #expect(await keeper.replaceFerryServer(fetched: Self.adb))
    fakes { $0.answering = true }
    #expect(await keeper.replaceFerryServer(fetched: Self.adb) == false)
    #expect(fakes { $0.kills } == 1)
  }

  @Test func anotherAdbListeningIsLeftAlone() async {
    let fakes = Fakes()
    fakes { state in
      state.answering = true
      state.listener = 33
      state.paths[33] = "/opt/homebrew/bin/adb"
    }
    let keeper = Self.keeper(fakes, record: Self.recordFile())
    #expect(await keeper.replaceFerryServer(fetched: Self.adb) == false)
    #expect(await keeper.replaceFerryServer(fetched: nil) == false)
    #expect(fakes { $0.kills } == 0)
  }

  /// The agent's own child is working as it should: it is never the stale one.
  @Test func theAgentsOwnServerIsNotReplaced() async throws {
    let fakes = Fakes()
    let record = Self.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    let keeper = Self.keeper(fakes, record: record)
    try await keeper.start(Self.adb)
    fakes { $0.listener = 4242 }
    #expect(await keeper.replaceFerryServer(fetched: Self.adb) == false)
    #expect(fakes { $0.kills } == 0)
  }
}

/// The real process layer: a spawned server stays in the agent's process group, which launchd
/// ends with the agent, and the table reads a process's start, program and listening port.
struct ADBServerProcessTests {
  @Test func aSpawnedServerStaysInTheCallersProcessGroup() throws {
    let spawner = SystemServerSpawner()
    let pid = try spawner.spawn(URL(filePath: "/bin/sleep"), arguments: ["30"])
    defer { kill(pid, SIGKILL) }
    #expect(getpgid(pid) == getpgrp())
    #expect(spawner.hasExited(pid) == false)
  }

  @Test func theTableReadsThisProcess() throws {
    let table = SystemProcessTable()
    #expect(table.started(getpid()) != nil)
    #expect(table.started(getpid()) == table.started(getpid()))
    #expect(table.path(getpid()) == Bundle.main.executableURL?.resolvingSymlinksInPath().path)
  }

  @Test func theTableFindsTheListenerOnAPort() throws {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try #require(socket >= 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0 && listen(socket, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    #expect(SystemProcessTable().listener(onTCPPort: port) == getpid())
  }
}
