import Darwin
import Foundation
import PlatformTools
import os

/// What Remove Ferry deletes on the Mac once the agent is unregistered (audit M8):
/// `~/Library/Application Support/Ferry` (the fetched adb and the licence acceptance) and the
/// agent's own folder beside it (item tables, remembered devices and their addresses, the
/// capture journal, the adb server record).
///
/// Unregistering does not wait for the agent to exit (SMAppService), and an agent still saving
/// could write a table back, so this first waits, at most `agentWait`, until no process runs the
/// agent's program. It then stops any adb server still running Ferry's fetched adb (matched by
/// its resolved path, and by its start time again just before the signal, so a recycled PID is
/// never hit), which would otherwise outlive its deleted program. A server from any other adb
/// (Homebrew's, the Android SDK's) is never touched; nor is one the agent started from such an
/// adb. Last it deletes both folders, except one holding changes the system saved.
struct FerryDataRemoval {
  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Removal")
  static let agentWait = Duration.seconds(5)
  static let agentPoll = Duration.milliseconds(100)

  let folders: [URL]
  let platformTools: URL
  let agent: String
  let table: any ProcessTable
  let terminate: @Sendable (pid_t) -> Void
  /// Waits one poll; tests pass one that returns at once.
  let pause: @Sendable () async -> Void

  init(
    home: URL, agent: URL, table: any ProcessTable,
    terminate: @escaping @Sendable (pid_t) -> Void,
    pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: agentPoll) }
  ) {
    let tools = PlatformToolsFolder(home: home.path).root
    let ferry = tools.deletingLastPathComponent()
    folders = [
      ferry,
      ferry.deletingLastPathComponent()
        .appending(path: "io.github.krisarmstrong.ferry.agent", directoryHint: .isDirectory),
    ]
    platformTools = tools
    self.agent = agent.resolvingSymlinksInPath().path
    self.table = table
    self.terminate = terminate
    self.pause = pause
  }

  static var standard: FerryDataRemoval {
    FerryDataRemoval(
      home: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
      agent: Bundle.main.bundleURL.appending(path: "Contents/MacOS/FerryAgent"),
      table: SystemProcessTable(), terminate: { _ = kill($0, SIGTERM) })
  }

  /// Waits for the agent to exit, stops Ferry's adb servers, then deletes each folder that holds
  /// none of `preserved`.
  func run(keeping preserved: [URL]) async {
    await waitForTheAgent()
    stopFerrysADB()
    for folder in folders {
      let prefix = folder.resolvingSymlinksInPath().path + "/"
      guard
        !preserved.contains(where: {
          ($0.resolvingSymlinksInPath().path + "/").hasPrefix(prefix)
        })
      else {
        Self.log.error("kept a data folder holding saved changes")
        continue
      }
      do {
        try FileManager.default.removeItem(at: folder)
      } catch CocoaError.fileNoSuchFile {
        continue
      } catch {
        Self.log.error("deleting Ferry's data failed: \(error, privacy: .private)")
      }
    }
  }

  private func waitForTheAgent() async {
    let polls = Int(Self.agentWait / Self.agentPoll)
    for _ in 0..<polls {
      guard table.processes().contains(where: { table.path($0) == agent }) else { return }
      await pause()
    }
    Self.log.error("the agent was still running; deleting its data anyway")
  }

  /// A process that runs Ferry's adb, as first seen.
  private struct Server {
    let pid: pid_t
    let path: String
    let started: UInt64
  }

  private func stopFerrysADB() {
    let tools = platformTools.resolvingSymlinksInPath().path + "/"
    let servers = table.processes().compactMap { pid -> Server? in
      guard let path = table.path(pid), path.hasPrefix(tools),
        (path as NSString).lastPathComponent == "adb", let started = table.started(pid)
      else { return nil }
      return Server(pid: pid, path: path, started: started)
    }
    for server in servers
    where table.started(server.pid) == server.started && table.path(server.pid) == server.path {
      terminate(server.pid)
    }
  }

}
