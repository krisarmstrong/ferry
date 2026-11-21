import Darwin
import Foundation
import PlatformTools
import Synchronization

/// Starts the adb server as a child of this process. `ADBServerKeeper` uses it; tests fake it.
protocol ADBServerSpawner: Sendable {
  /// Runs `adb` with `arguments` in this process's process group, and returns its PID.
  func spawn(_ adb: URL, arguments: [String]) throws(ADBError) -> pid_t
  /// Whether a process `spawn` started has exited.
  func hasExited(_ pid: pid_t) -> Bool
}

/// `posix_spawn` without a new process group or session: launchd ends every process in the
/// agent's group when the agent exits (launchd.plist(5), AbandonProcessGroup), so a server
/// started here does not outlive it. Nothing else of the agent's is inherited: no descriptors
/// beyond /dev/null for the standard three, no blocked or ignored signals.
final class SystemServerSpawner: ADBServerSpawner {
  /// Exited children, reaped as they exit so none lingers as a zombie.
  private let exited = Mutex<Set<pid_t>>([])
  private let reapers = Mutex<[pid_t: any DispatchSourceProcess]>([:])

  func spawn(_ adb: URL, arguments: [String]) throws(ADBError) -> pid_t {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw .failed("could not run adb") }
    defer { posix_spawnattr_destroy(&attributes) }
    var none = sigset_t()
    var all = sigset_t()
    sigemptyset(&none)
    sigfillset(&all)
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw .failed("could not run adb") }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let prepared = [
      posix_spawnattr_setsigmask(&attributes, &none),
      posix_spawnattr_setsigdefault(&attributes, &all),
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)),
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
      posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0),
      posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0),
    ]
    guard prepared.allSatisfy({ $0 == 0 }) else { throw .failed("could not run adb") }
    let argv = ([adb.path] + arguments).map { strdup($0) } + [nil]
    defer {
      for argument in argv { free(argument) }
    }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, adb.path, &actions, &attributes, argv, environ)
    guard status == 0 else {
      throw .failed("could not run adb: \(String(cString: strerror(status)))")
    }
    let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
    reaper.setEventHandler { [self] in
      var code: Int32 = 0
      waitpid(pid, &code, 0)
      exited.withLock { _ = $0.insert(pid) }
      reapers.withLock { $0.removeValue(forKey: pid) }?.cancel()
    }
    // A PID reused from an earlier child is not that child, which exited.
    exited.withLock { _ = $0.remove(pid) }
    reapers.withLock { $0[pid] = reaper }
    reaper.resume()
    // One that exited before the reaper listened is reaped here, not left a zombie.
    _ = hasExited(pid)
    return pid
  }

  func hasExited(_ pid: pid_t) -> Bool {
    if exited.withLock({ $0.contains(pid) }) { return true }
    // It may exit before the reaper is listening, which then never fires.
    var code: Int32 = 0
    guard waitpid(pid, &code, WNOHANG) == pid else { return false }
    exited.withLock { _ = $0.insert(pid) }
    return true
  }
}
