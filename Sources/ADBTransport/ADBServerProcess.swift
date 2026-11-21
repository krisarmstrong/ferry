import Darwin
import Foundation

/// The `adb` a shell in Terminal runs (see `ADBDeviceTools.shellADB()`).
public struct ShellADB: Sendable, Equatable {
  public let url: URL
  /// Whether it is the program serving the adb server's port. False when Ferry could not tell
  /// which program that is and fell back to the adb the locator finds: an adb client of another
  /// version than the server may restart it.
  public let runsServer: Bool

  public init(url: URL, runsServer: Bool) {
    self.url = url
    self.runsServer = runsServer
  }
}

/// Which program serves the adb server: the process listening on its TCP port, read through
/// libproc. Only this user's processes can be read, which is where an adb server started from
/// this account runs.
enum ADBServerProcess {
  /// The executable of the process listening on TCP `port`, if one can be read.
  static func executable(listeningOn port: UInt16) -> URL? {
    allProcesses().first { listens($0, on: port) }.flatMap(path(of:))
  }

  private static func allProcesses() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    // Room for processes started between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(count) + 32)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    return filled > 0 ? Array(pids.prefix(Int(filled))) : []
  }

  private static func listens(_ pid: pid_t, on port: UInt16) -> Bool {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return false }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    guard filled > 0 else { return false }
    return fds.prefix(Int(filled) / stride).contains { descriptor in
      guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return false }
      var info = socket_fdinfo()
      let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
      guard
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
        info.psi.soi_kind == SOCKINFO_TCP
      else { return false }
      let tcp = info.psi.soi_proto.pri_tcp
      // The local port is in network byte order in the low 16 bits.
      let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
      return tcp.tcpsi_state == TSI_S_LISTEN && local == port
    }
  }

  static func path(of pid: pid_t) -> URL? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(bytes: buffer.prefix(Int(length)), encoding: .utf8).map(
      URL.init(fileURLWithPath:))
  }
}
