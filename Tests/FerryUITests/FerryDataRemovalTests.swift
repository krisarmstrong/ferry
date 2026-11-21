import DeviceKitTestSupport
import Foundation
import PlatformTools
import Synchronization
import Testing

@testable import FerryUI

/// The PIDs a removal signalled.
final class Stopped: Sendable {
  let pids = Mutex<[pid_t]>([])
}

/// A process in `FakeTable`: its program and start time.
struct FakeProcess {
  var path: String
  var started: UInt64
}

/// Remove Ferry deletes what Ferry kept on the Mac once its helper has exited, and stops an adb
/// server only when it runs Ferry's own fetched adb (audit M8, W5 review).
struct FerryDataRemovalTests {
  /// Processes by PID: their program and start time, which tests change as processes come and
  /// go. Each `processes()` call counts as one poll.
  final class FakeTable: ProcessTable {
    private let state = Mutex<(processes: [pid_t: FakeProcess], polls: Int)>(([:], 0))
    /// Called on each poll with its number, to change the table as time passes.
    let onPoll: @Sendable (Int, inout [pid_t: FakeProcess]) -> Void

    init(
      _ processes: [pid_t: FakeProcess], recycled: pid_t? = nil,
      onPoll: @escaping @Sendable (Int, inout [pid_t: FakeProcess]) -> Void = { _, _ in }
    ) {
      state.withLock { $0.processes = processes }
      self.recycled = recycled
      self.onPoll = onPoll
    }

    var polls: Int { state.withLock { $0.polls } }

    func processes() -> [pid_t] {
      state.withLock { state in
        state.polls += 1
        onPoll(state.polls, &state.processes)
        return Array(state.processes.keys).sorted()
      }
    }
    /// A PID whose process is replaced by another right after its start time is first read.
    let recycled: pid_t?
    private let looks = Mutex<[pid_t: Int]>([:])

    func started(_ pid: pid_t) -> UInt64? {
      let look = looks.withLock { looks in
        looks[pid, default: 0] += 1
        return looks[pid]!
      }
      let started = state.withLock { $0.processes[pid]?.started }
      return pid == recycled && look > 1 ? started.map { $0 + 1 } : started
    }
    func path(_ pid: pid_t) -> String? { state.withLock { $0.processes[pid]?.path } }
    func listener(onTCPPort port: UInt16) -> pid_t? { nil }
    func runsGoogleADB(_ pid: pid_t) -> Bool { false }
  }

  private let home = TestScratch.root.appending(
    path: "ferry-home-\(UUID().uuidString)", directoryHint: .isDirectory)

  private var agent: URL { home.appending(path: "Ferry.app/Contents/MacOS/FerryAgent") }
  /// The agent's program as the process table reports it: with links resolved.
  private var agentPath: String { agent.resolvingSymlinksInPath().path }

  private func make(_ relative: String, file: String) throws -> URL {
    let folder = home.appending(path: relative, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: file)
    try Data("x".utf8).write(to: url)
    return url
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// Stands in for the user's Trash: removal moves folders here, never into the real Trash.
  private var trash: URL { home.appending(path: ".Trash", directoryHint: .isDirectory) }

  private func removal(_ table: FakeTable, stopped: Stopped = Stopped())
    -> FerryDataRemoval
  {
    let trash = trash
    return FerryDataRemoval(
      home: home, agent: agent, table: table,
      terminate: { pid in stopped.pids.withLock { $0.append(pid) } }, pause: {},
      discard: { folder in
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
          at: folder, to: trash.appending(path: folder.lastPathComponent))
      })
  }

  @Test func ferrysDataGoes() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let adb = try make("Library/Application Support/Ferry/platform-tools/36.0.0", file: "adb")
    let accepted = try make("Library/Application Support/Ferry", file: "license.json")
    let table = try make(
      "Library/Application Support/io.github.krisarmstrong.ferry.agent/items", file: "a.json")
    let remembered = try make(
      "Library/Application Support/io.github.krisarmstrong.ferry.agent", file: "wireless.json")
    let other = try make("Library/Application Support/SomethingElse", file: "keep.json")

    await removal(FakeTable([:])).run(keeping: [])

    for url in [adb, accepted, table, remembered] { #expect(!exists(url), "\(url.path)") }
    #expect(exists(other))
  }

  /// Ferry's data goes to the Trash, not away for good: a Remove Ferry clicked by mistake can be
  /// undone by putting the folders back.
  @Test func ferrysDataGoesToTheTrash() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try make("Library/Application Support/Ferry/platform-tools/36.0.0", file: "adb")
    _ = try make("Library/Application Support/Ferry", file: "license.json")
    _ = try make(
      "Library/Application Support/io.github.krisarmstrong.ferry.agent", file: "wireless.json")

    await removal(FakeTable([:])).run(keeping: [])

    #expect(exists(trash.appending(path: "Ferry/platform-tools/36.0.0/adb")))
    #expect(exists(trash.appending(path: "Ferry/license.json")))
    #expect(exists(trash.appending(path: "io.github.krisarmstrong.ferry.agent/wireless.json")))
  }

  /// Unregistering does not wait for the agent: nothing is deleted until it has exited, so it
  /// cannot write a table back afterwards.
  @Test func nothingGoesUntilTheAgentHasExited() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let remembered = try make(
      "Library/Application Support/io.github.krisarmstrong.ferry.agent", file: "wireless.json")
    let agentPath = agentPath
    let table = FakeTable([7: .init(path: agentPath, started: 1)]) { poll, processes in
      // The agent writes while it lives, and exits on the fourth poll.
      if poll < 4 {
        #expect(FileManager.default.fileExists(atPath: remembered.path))
      } else {
        processes[7] = nil
      }
    }
    await removal(table).run(keeping: [])
    #expect(table.polls >= 4)
    #expect(!exists(remembered))
  }

  /// An agent that never exits holds Remove Ferry up only for the bounded wait.
  @Test func theWaitIsBounded() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let table = FakeTable([7: .init(path: agentPath, started: 1)])
    await removal(table).run(keeping: [])
    #expect(table.polls <= Int(FerryDataRemoval.agentWait / FerryDataRemoval.agentPoll) + 2)
  }

  /// Only an adb running from Ferry's own platform-tools folder is stopped: never a server the
  /// user started from Homebrew or the Android SDK, nor anything else.
  @Test func onlyFerrysAdbServerIsStopped() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let ferryADB = try make("Library/Application Support/Ferry/platform-tools/36.0.0", file: "adb")
    let table = FakeTable([
      101: .init(path: ferryADB.resolvingSymlinksInPath().path, started: 1),
      102: .init(path: "/opt/homebrew/bin/adb", started: 1),
      103: .init(path: home.path + "/Library/Android/sdk/platform-tools/adb", started: 1),
      104: .init(
        path: home.path + "/Library/Application Support/Ferry/platform-tools/x/other", started: 1),
    ])
    let stopped = Stopped()
    await removal(table, stopped: stopped).run(keeping: [])
    #expect(stopped.pids.withLock { $0 } == [101])
  }

  /// A PID whose process changed between the scan and the signal (it exited and the PID was
  /// reused) is not signalled.
  @Test func aRecycledPIDIsNotSignalled() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let ferryADB = try make("Library/Application Support/Ferry/platform-tools/36.0.0", file: "adb")
    let path = ferryADB.resolvingSymlinksInPath().path
    let table = FakeTable([101: .init(path: path, started: 1)], recycled: 101)
    let stopped = Stopped()
    await removal(table, stopped: stopped).run(keeping: [])
    #expect(stopped.pids.withLock { $0 }.isEmpty)
  }

  /// Changes the system saved for a removed location are never deleted with Ferry's data.
  @Test func aFolderHoldingSavedChangesIsKept() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let saved = try make("Library/Application Support/Ferry/unsent", file: "report.txt")
    await removal(FakeTable([:])).run(keeping: [saved.deletingLastPathComponent()])
    #expect(exists(saved))
  }

  /// A folder that is a link loses the link, not what it points to.
  @Test func aLinkedFolderLosesOnlyTheLink() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let elsewhere = try make("Elsewhere", file: "keep.txt")
    let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: support.appending(path: "Ferry"),
      withDestinationURL: elsewhere.deletingLastPathComponent())
    await removal(FakeTable([:])).run(keeping: [])
    #expect(exists(elsewhere))
    #expect(!exists(support.appending(path: "Ferry")))
  }
}
