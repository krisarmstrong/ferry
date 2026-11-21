import Darwin
import Foundation

/// What Ferry reads about other processes of the same user: the agent's adb server keeper,
/// and Remove Ferry, which stops only Ferry's own adb.
public protocol ProcessTable: Sendable {
  /// Every process the table can see.
  func processes() -> [pid_t]
  /// When the process started, in microseconds since 1970: with the PID, it names one process.
  func started(_ pid: pid_t) -> UInt64?
  /// The process's program.
  func path(_ pid: pid_t) -> String?
  /// The process listening on `port` over TCP on 127.0.0.1, where `host:kill` goes.
  func listener(onTCPPort port: UInt16) -> pid_t?
  /// Whether the code the process runs is Google's `adb`.
  func runsGoogleADB(_ pid: pid_t) -> Bool
}

/// libproc, for processes the agent may read: those of the same user.
public struct SystemProcessTable: ProcessTable {
  public init() {}

  public func processes() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(max(0, Int(listed))).filter { $0 > 0 }
  }

  public func runsGoogleADB(_ pid: pid_t) -> Bool { CodeSignature.isRunningGoogleSigned(pid: pid) }

  public func started(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
  }

  public func path(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(bytes: buffer.prefix(Int(length)), encoding: .utf8)
  }

  public func listener(onTCPPort port: UInt16) -> pid_t? {
    processes().first { listens($0, on: port) }
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

  /// 127.0.0.1, where `host:kill` goes (`ADBStream` connects to IPv4 loopback only).
  public static func isLoopback(_ address: in_sockinfo) -> Bool {
    address.insi_vflag & UInt8(INI_IPV4) != 0
      && UInt32(bigEndian: address.insi_laddr.ina_46.i46a_addr4.s_addr) == 0x7F00_0001
  }
}
