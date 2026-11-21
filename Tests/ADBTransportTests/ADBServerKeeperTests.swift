import Darwin
import DeviceKitTestSupport
import Foundation
import PlatformTools
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
    /// Processes whose running code is Google's adb.
    var googleADB: Set<pid_t> = []
    /// The program the kernel reports for a spawned server, when it differs from the URL run.
    var resolved: String?
    /// A wedged server: it takes the connection and never answers, ignoring cancellation.
    var killHangs = false
    var answersHang = false
    var kills = 0
    /// How many more times a started server does not answer yet, as one coming up does.
    var notYet = 0
    /// What a spawned server sets `notYet` to.
    var slowStart = 0
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
        state.paths[pid] = state.resolved ?? adb.path
        state.started[pid] = 777
        state.nextPID += 1
        state.notYet = state.slowStart
        if state.serverComesUp { state.answering = true } else { state.exited.insert(pid) }
        return pid
      }
    }

    func hasExited(_ pid: pid_t) -> Bool { fakes { $0.exited.contains(pid) } }
  }

  struct FakeTable: ProcessTable {
    let fakes: Fakes

    func processes() -> [pid_t] { fakes { Array($0.paths.keys) } }
    func started(_ pid: pid_t) -> UInt64? { fakes { $0.started[pid] } }
    func path(_ pid: pid_t) -> String? { fakes { $0.paths[pid] } }
    func listener(onTCPPort port: UInt16) -> pid_t? { fakes { $0.listener } }
    func runsGoogleADB(_ pid: pid_t) -> Bool { fakes { $0.googleADB.contains(pid) } }
  }

  static let adb = URL(
    filePath: "/Users/me/Library/Application Support/Ferry/platform-tools/37/adb")

  static func recordFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ferry-adb-server-\(UUID()).json")
  }

  /// `exits` is how long a killed server takes to exit (its PID stops running), on `clock`: at
  /// once if nil. `clock` moves only when a test moves it, so no limit runs out by itself.
  /// `whileStopping` runs inside the kill, as a tracker restarting the server would.
  static func keeper(
    _ fakes: Fakes, record: URL, exits: Duration? = nil, limit: Duration = .seconds(2),
    callLimit: Duration = .milliseconds(300), clock: any Clock<Duration> = ManualClock(),
    exists: @escaping @Sendable (String) -> Bool = { _ in true },
    whileStopping: (@Sendable () async -> Void)? = nil
  ) -> ADBServerKeeper {
    ADBServerKeeper(
      port: 5037, record: record, spawner: FakeSpawner(fakes: fakes),
      table: FakeTable(fakes: fakes),
      answers: {
        if fakes({ $0.answersHang }) { await Self.never() }
        return fakes { state in
          guard state.notYet == 0 else {
            state.notYet -= 1
            return false
          }
          return state.answering
        }
      },
      kill: {
        if fakes({ $0.killHangs }) { await Self.never() }
        let pid = fakes { state -> pid_t? in
          state.kills += 1
          state.answering = false
          return state.listener
        }
        await whileStopping?()
        guard let pid else { return }
        // An exited server runs no more and holds the port no more.
        let exit = { @Sendable in
          fakes { state in
            state.started[pid] = nil
            if state.listener == pid { state.listener = nil }
          }
        }
        guard let exits else { return exit() }
        Task {
          try? await clock.sleep(for: exits)
          exit()
        }
      },
      limit: limit, poll: .milliseconds(10), callLimit: callLimit, clock: clock, exists: exists)
  }

  /// A keeper for tests of what runs inside its gate: there is never a replacement.
  static func idle() -> ADBServerKeeper {
    let fakes = Fakes()
    return ADBServerKeeper(
      port: 0, record: recordFile(), spawner: FakeSpawner(fakes: fakes),
      table: FakeTable(fakes: fakes), answers: { true }, kill: {})
  }

  /// Suspends for good, cancelled or not.
  static func never() async {
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
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

  /// The transport's and the wireless side's trackers both start the server after an outage:
  /// one server is started, and the record names it. Time moves only by the test's hand, in poll
  /// steps, and the limits are far beyond the polls a slow start takes, so only the count is
  /// tested: a loaded machine cannot run past a limit.
  @Test(.timeLimit(.minutes(1)))
  func startsAtOnceRunOneServer() async throws {
    let fakes = Fakes()
    fakes { $0.slowStart = 5 }
    let record = Self.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    let clock = ManualClock()
    let keeper = Self.keeper(
      fakes, record: record, limit: .seconds(3600), callLimit: .seconds(3600), clock: clock)
    try await clock.advancing(by: .milliseconds(10)) {
      async let first: Void = keeper.start(Self.adb)
      async let second: Void = keeper.start(Self.adb)
      _ = try await (first, second)
    }
    #expect(fakes { $0.spawned.count } == 1)
    #expect(ADBServerRecord.load(record)?.pid == 4242)
  }

  /// Written as the agent's other stores are: 0600 in a 0700 folder made for it. The program is
  /// the kernel's, symlinks resolved, as the orphan check reads it back.
  @Test func theRecordIsPrivateAndNamesTheResolvedProgram() async throws {
    let fakes = Fakes()
    fakes { $0.resolved = "/opt/homebrew/Caskroom/android-platform-tools/37/platform-tools/adb" }
    let folder = FileManager.default.temporaryDirectory.appending(path: "ferry-agent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let record = folder.appending(path: "adb-server.json")
    try await Self.keeper(fakes, record: record).start(URL(filePath: "/opt/homebrew/bin/adb"))
    let saved = try #require(ADBServerRecord.load(record))
    #expect(saved.path == "/opt/homebrew/Caskroom/android-platform-tools/37/platform-tools/adb")
    let mode = { (url: URL) in
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
    #expect(mode(record) == 0o600)
    #expect(mode(folder) == 0o700)
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
      state.listener = 9
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
      state.listener = 9
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
      state.googleADB = [33]
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

  /// `host:kill` goes to 127.0.0.1, so only an IPv4 loopback listener is the one it reaches.
  @Test func onlyIPv4LoopbackIsTheKillTarget() {
    var ipv4 = in_sockinfo()
    ipv4.insi_vflag = UInt8(INI_IPV4)
    ipv4.insi_laddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.1")
    var ipv6 = in_sockinfo()
    ipv6.insi_vflag = UInt8(INI_IPV6)
    ipv6.insi_laddr.ina_6 = in6addr_loopback
    var anywhere = in_sockinfo()
    anywhere.insi_vflag = UInt8(INI_IPV4)
    #expect(SystemProcessTable.isLoopback(ipv4))
    #expect(SystemProcessTable.isLoopback(ipv6) == false)
    #expect(SystemProcessTable.isLoopback(anywhere) == false)
  }

  @Test func thisProcessDoesNotRunGooglesADB() {
    #expect(SystemProcessTable().runsGoogleADB(getpid()) == false)
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
