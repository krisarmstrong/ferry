import DeviceKit
import Foundation

public struct ADBStat: Sendable, Equatable {
  public let mode: UInt32
  public let size: UInt64
  public let mtime: Date

  public init(mode: UInt32, size: UInt64, mtime: Date) {
    self.mode = mode
    self.size = size
    self.mtime = mtime
  }

  private static let typeMask: UInt32 = 0o170000
  public var isDirectory: Bool { mode & Self.typeMask == 0o040000 }
  public var isRegular: Bool { mode & Self.typeMask == 0o100000 }
}

/// The adb sync service (`sync:`) over one connection. Requests run one at a time: the actor
/// serialises them, and each reads its whole reply before the next starts. A transfer that is
/// stopped by its progress handler closes the connection, since the reply stream is then
/// mid-file; open a new `sync:` for further work.
public actor ADBSync {
  /// Sync's `SYNC_DATA_MAX`: no side sends a DATA chunk larger than this.
  private static let chunkLimit = 64 * 1024
  private static let enoent: UInt32 = 2
  private static let nameLimit = 1024

  private let stream: ADBStream
  private let statV2: Bool
  private let listV2: Bool

  public init(stream: ADBStream, features: Set<String>) {
    self.stream = stream
    self.statV2 = features.contains("stat_v2")
    self.listV2 = features.contains("ls_v2")
  }

  /// nil when the path does not exist.
  public func stat(_ path: String) async throws(ADBError) -> ADBStat? {
    if statV2 {
      try await request("STA2", path)
      try await expect("STA2")
      let body = try await stream.read(exactly: Self.stat2Length)
      let error = ADBWire.u32(body.prefix(4))
      if error == Self.enoent { return nil }
      guard error == 0 else { throw .failed("stat \(path) failed with errno \(error)") }
      return Self.stat2(body)
    }
    try await request("STAT", path)
    try await expect("STAT")
    let body = Array(try await stream.read(exactly: 12))
    let mode = ADBWire.u32(body[0..<4])
    let size = ADBWire.u32(body[4..<8])
    let mtime = ADBWire.u32(body[8..<12])
    // The server answers a missing path with all zeros.
    if mode == 0 && size == 0 && mtime == 0 { return nil }
    return ADBStat(
      mode: mode, size: UInt64(size), mtime: Date(timeIntervalSince1970: TimeInterval(mtime)))
  }

  public typealias Entry = (name: String, stat: ADBStat)

  public func list(_ dir: String) async throws(ADBError) -> [Entry] {
    var entries = try await (listV2 ? listWithLis2(dir) : listWithList(dir))
    guard !listV2, statV2 else { return entries }
    // LIST carries 32-bit sizes, so a regular file over 4 GB reads short; STA2 has the truth.
    let prefix = dir.hasSuffix("/") ? dir : dir + "/"
    for index in entries.indices where entries[index].stat.isRegular {
      if let exact = try await stat(prefix + entries[index].name) {
        entries[index].stat = exact
      }
    }
    return entries
  }

  /// Streams the file into `file`. `progress` is told the bytes received and the size `stat`
  /// reported; returning false stops the transfer with `.cancelled` and closes the connection.
  public func receive(
    _ path: String, to file: FileHandle, progress: ProgressHandler
  ) async throws(ADBError) -> UInt64 {
    let total = try await stat(path)?.size ?? 0
    try await request("RECV", path)
    var received: UInt64 = 0
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
      switch id {
      case "DATA":
        guard length <= Self.chunkLimit else {
          throw .protocolViolation("DATA chunk of \(length) bytes")
        }
        let chunk = try await stream.read(exactly: length)
        do {
          try file.write(contentsOf: chunk)
        } catch {
          await stream.close()
          throw .failed("could not write the received data: \(error.localizedDescription)")
        }
        received += UInt64(length)
        guard progress(received, total) else {
          await stream.close()
          throw .cancelled
        }
      case "DONE":
        return received
      case "FAIL":
        throw .failed(try ADBWire.text(try await stream.read(exactly: length)))
      default:
        throw .protocolViolation("unexpected \(id) in a receive")
      }
    }
  }

  /// Streams `file`, from its current offset to its end, to `path` on the device. The device
  /// applies `mode` (a full st_mode, such as 0o100644) and `mtime`. `progress` stopping the
  /// transfer throws `.cancelled` and closes the connection before the file is finished, so the
  /// caller removes whatever was created at `path`.
  public func send(
    _ file: FileHandle, to path: String, mode: UInt32, mtime: Date, progress: ProgressHandler
  ) async throws(ADBError) {
    let start: UInt64
    let total: UInt64
    do {
      start = try file.offset()
      total = try file.seekToEnd() - start
      try file.seek(toOffset: start)
    } catch {
      throw .failed("could not size the file to send: \(error.localizedDescription)")
    }
    try await request("SEND", "\(path),\(mode)")
    var sent: UInt64 = 0
    while sent < total {
      let chunk: Data
      do {
        chunk = try file.read(upToCount: Self.chunkLimit) ?? Data()
      } catch {
        await stream.close()
        throw .failed("could not read the file to send: \(error.localizedDescription)")
      }
      guard !chunk.isEmpty else {
        await stream.close()
        throw .failed("the file shrank while it was being sent")
      }
      try await stream.write(Data("DATA".utf8) + ADBWire.le32(UInt32(chunk.count)) + chunk)
      sent += UInt64(chunk.count)
      guard progress(sent, total) else {
        await stream.close()
        throw .cancelled
      }
    }
    let seconds = UInt32(clamping: Int64(mtime.timeIntervalSince1970.rounded(.down)))
    try await stream.write(Data("DONE".utf8) + ADBWire.le32(seconds))
    let id = try ADBWire.text(try await stream.read(exactly: 4))
    let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
    switch id {
    case "OKAY": return
    case "FAIL": throw .failed(try ADBWire.text(try await stream.read(exactly: length)))
    default: throw .protocolViolation("unexpected \(id) after a send")
    }
  }

  public func quit() async {
    try? await stream.write(Data("QUIT".utf8) + ADBWire.le32(0))
    await stream.close()
  }

  // MARK: protocol

  /// 4-byte id, little-endian length, then the path or argument.
  private func request(_ id: String, _ argument: String) async throws(ADBError) {
    let payload = Data(argument.utf8)
    guard payload.count <= Self.nameLimit * 4 else {
      throw .protocolViolation("path of \(payload.count) bytes")
    }
    try await stream.write(Data(id.utf8) + ADBWire.le32(UInt32(payload.count)) + payload)
  }

  /// Reads a reply id, turning `FAIL` into its message.
  private func expect(_ id: String) async throws(ADBError) {
    let got = try ADBWire.text(try await stream.read(exactly: 4))
    if got == "FAIL" {
      let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
      throw .failed(try ADBWire.text(try await stream.read(exactly: length)))
    }
    guard got == id else { throw .protocolViolation("expected \(id), got \(got)") }
  }

  /// error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime.
  private static let stat2Length = 68

  private static func stat2(_ body: Data) -> ADBStat {
    let bytes = Array(body)
    return ADBStat(
      mode: ADBWire.u32(bytes[20..<24]), size: ADBWire.u64(bytes[36..<44]),
      mtime: Date(
        timeIntervalSince1970: TimeInterval(Int64(bitPattern: ADBWire.u64(bytes[52..<60])))))
  }

  private func listWithLis2(_ dir: String) async throws(ADBError) -> [Entry] {
    try await request("LIS2", dir)
    var entries: [Entry] = []
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      switch id {
      case "DNT2":
        let body = try await stream.read(exactly: Self.stat2Length)
        let name = try await readName()
        guard ADBWire.u32(body.prefix(4)) == 0 else { continue }
        Self.append(name, Self.stat2(body), to: &entries)
      case "DONE":
        _ = try await stream.read(exactly: Self.stat2Length + 4)
        return entries
      case "FAIL":
        let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
        throw .failed(try ADBWire.text(try await stream.read(exactly: length)))
      default:
        throw .protocolViolation("unexpected \(id) in a listing")
      }
    }
  }

  private func listWithList(_ dir: String) async throws(ADBError) -> [Entry] {
    try await request("LIST", dir)
    var entries: [Entry] = []
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      switch id {
      case "DENT":
        let body = Array(try await stream.read(exactly: 12))
        let stat = ADBStat(
          mode: ADBWire.u32(body[0..<4]), size: UInt64(ADBWire.u32(body[4..<8])),
          mtime: Date(timeIntervalSince1970: TimeInterval(ADBWire.u32(body[8..<12]))))
        Self.append(try await readName(), stat, to: &entries)
      case "DONE":
        _ = try await stream.read(exactly: 16)
        return entries
      case "FAIL":
        let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
        throw .failed(try ADBWire.text(try await stream.read(exactly: length)))
      default:
        throw .protocolViolation("unexpected \(id) in a listing")
      }
    }
  }

  /// nil for a name that is not UTF-8: it could not be addressed again, so it is not listed.
  private func readName() async throws(ADBError) -> String? {
    let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
    guard length <= Self.nameLimit else { throw .protocolViolation("name of \(length) bytes") }
    return String(bytes: try await stream.read(exactly: length), encoding: .utf8)
  }

  private static func append(
    _ name: String?, _ stat: ADBStat, to entries: inout [Entry]
  ) {
    guard let name, name != ".", name != ".." else { return }
    entries.append((name, stat))
  }
}
