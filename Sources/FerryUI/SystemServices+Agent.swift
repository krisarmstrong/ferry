import Darwin
import Foundation
import PlatformTools
import os

/// Finding the agent's process, and removing a launchd job that cannot spawn it.
extension SystemServices {
  /// The agent's launchd label, from its plist.
  private nonisolated static let agentLabel = "io.github.krisarmstrong.ferry.agent"
  /// How long a bootout may take to leave launchd without the job, and how often to look.
  private nonisolated static let bootOutWait = Duration.seconds(5)
  private nonisolated static let bootOutPoll = Duration.milliseconds(100)

  public func bootOutAgent() async {
    await Task.detached(priority: .utility) {
      // This user's job only, by Ferry's own label.
      let service = "gui/\(getuid())/\(Self.agentLabel)"
      let status = await Self.launchctl(["bootout", service])
      Self.log.notice("booted out the agent's job: \(status, privacy: .public)")
      // bootout can return while launchd is still removing the job.
      for _ in 0..<Int(Self.bootOutWait / Self.bootOutPoll) {
        guard await Self.launchctl(["print", service]) == 0 else { return }
        try? await Task.sleep(for: Self.bootOutPoll)
      }
      Self.log.error("launchd still lists the agent's job after a bootout")
    }.value
  }

  /// Runs `/bin/launchctl` with `arguments`, discarding its output; its exit status, or -1 if it
  /// could not run.
  private nonisolated static func launchctl(_ arguments: [String]) async -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return await withCheckedContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(returning: -1)
      }
    }
  }

  public func agentIsRunning() async -> Bool {
    let agent = Bundle.main.bundleURL.appending(path: "Contents/MacOS/FerryAgent")
      .resolvingSymlinksInPath().path
    return await Task.detached(priority: .utility) {
      let table = SystemProcessTable()
      return table.processes().contains { table.path($0) == agent && Self.isOwn($0) }
    }.value
  }

  /// Whether this user runs `pid`: another user's agent runs the same program.
  private nonisolated static func isOwn(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
  }
}
