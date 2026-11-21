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

/// What the keeper reads about other processes.
protocol ProcessTable: Sendable {
  /// When the process started, in microseconds since 1970: with the PID, it names one process.
  func started(_ pid: pid_t) -> UInt64?
  /// The process's program.
  func path(_ pid: pid_t) -> String?
  /// The process listening on `port` over TCP on a loopback address, where `host:kill` goes.
  func listener(onTCPPort port: UInt16) -> pid_t?
  /// Whether the code the process runs is Google's `adb`.
  func runsGoogleADB(_ pid: pid_t) -> Bool
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
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var none = sigset_t()
    var all = sigset_t()
    sigemptyset(&none)
    sigfillset(&all)
    posix_spawnattr_setsigmask(&attributes, &none)
    posix_spawnattr_setsigdefault(&attributes, &all)
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
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
    reapers.withLock { $0[pid] = reaper }
    reaper.resume()
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

/// libproc, for processes the agent may read: those of the same user.
struct SystemProcessTable: ProcessTable {
  func runsGoogleADB(_ pid: pid_t) -> Bool { CodeSignature.isRunningGoogleSigned(pid: pid) }

  func started(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
  }

  func path(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  func listener(onTCPPort port: UInt16) -> pid_t? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard listed > 0 else { return nil }
    return pids.prefix(Int(listed)).first { $0 > 0 && listens($0, on: port) }
  }

  private func listens(_ pid: pid_t, on port: UInt16) -> Bool {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return false }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
    let filled = proc_pidinfo(
      pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
    guard filled > 0 else { return false }
    return descriptors.prefix(Int(filled) / stride).contains { descriptor in
      guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return false }
      var socket = socket_fdinfo()
      let length = Int32(MemoryLayout<socket_fdinfo>.size)
      guard
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, length) == length,
        socket.psi.soi_kind == SOCKINFO_TCP
      else { return false }
      let tcp = socket.psi.soi_proto.pri_tcp
      return tcp.tcpsi_state == TSI_S_LISTEN
        && UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port
        && Self.isLoopback(tcp.tcpsi_ini)
    }
  }

  /// 127.0.0.0/8 or ::1: the addresses `host:kill` to localhost reaches.
  static func isLoopback(_ address: in_sockinfo) -> Bool {
    if address.insi_vflag & UInt8(INI_IPV4) != 0 {
      let ipv4 = UInt32(bigEndian: address.insi_laddr.ina_46.i46a_addr4.s_addr)
      return ipv4 >> 24 == 127
    }
    var loopback = in6addr_loopback
    var local = address.insi_laddr.ina_6
    return memcmp(&local, &loopback, MemoryLayout<in6_addr>.size) == 0
  }
}
