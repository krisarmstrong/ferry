import DeviceKit
import Foundation
import os

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

/// The adb sync service (`sync:`) over one connection.
///
/// Requests take turns: an actor alone lets a second call in at every `await`, so a gate holds
/// each request across its whole write and read. After any error other than a refused argument
/// (`.invalidArgument`, raised before anything is written) the connection is closed and this
/// object is dead: later calls throw `.connectionClosed`, so the caller opens a new `sync:`.
/// That covers a device `FAIL` (adbd ends the session after a failed RECV or SEND), a framing
/// error, a stat that fails, a cancelled or failed transfer. `.connectionClosed` is the
/// existing case that says exactly this, and callers already treat it as "reopen".
public actor ADBSync {
  /// Sync's `SYNC_DATA_MAX`: no side sends a DATA chunk larger than this.
  private static let chunkLimit = 64 * 1024
  private static let enoent: UInt32 = 2
  private static let enotdir: UInt32 = 20
  /// A file name is at most 255 bytes and a path at most PATH_MAX (4096) on the device, so no
  /// honest entry or request exceeds 4096.
  static let nameLimit = 4096
  /// adbd refuses a request longer than this (`path too long`) and ends the session.
  static let requestLimit = 1024
  /// Same bound as a DATA chunk: adbd's FAIL messages are short text.
  private static let messageLimit = 64 * 1024
  /// A hostile peer could stream entries forever; no real folder on a phone comes near this.
  static let defaultEntryLimit = 1_000_000
  /// How far past its `stat` size a download may grow (a file still being written) before it is
  /// taken for a device that will not stop sending.
  static let defaultGrowthAllowance: UInt64 = 64 << 20

  let stream: ADBStream
  private let statV2: Bool
  private let listV2: Bool
  let entryLimit: Int
  private let growthAllowance: UInt64
  private let gate = OperationGate()
  private var dead = false
  private var active = false

  public init(stream: ADBStream, features: Set<String>) {
    self.init(stream: stream, features: features, entryLimit: Self.defaultEntryLimit)
  }

  init(
    stream: ADBStream, features: Set<String>, entryLimit: Int,
    growthAllowance: UInt64 = defaultGrowthAllowance
  ) {
    self.stream = stream
    self.statV2 = features.contains("stat_v2")
    self.listV2 = features.contains("ls_v2")
    self.entryLimit = entryLimit
    self.growthAllowance = growthAllowance
  }

  /// Requests waiting for their turn behind the one in flight.
  var queuedRequests: Int { get async { await gate.waiting } }

  /// Runs one request alone on the connection, and ends the connection if it fails.
  private func perform<T>(
    _ body: () async throws(ADBError) -> T
  ) async throws(ADBError) -> T {
    try await gate.run { () async throws(ADBError) -> T in
      guard !dead else { throw .connectionClosed }
      // The gate cannot be cancelled while waiting, so a request queued in a cancelled task
      // finds out here, before it writes anything: the connection is untouched.
      if Task.isCancelled { throw .cancelled }
      active = true
      defer { active = false }
      do throws(ADBError) {
        return try await body()
      } catch {
        if case .invalidArgument = error {
        } else {
          dead = true
          await stream.close()
        }
        throw error
      }
    }
  }

  /// What is at `path` itself, a symbolic link included (`lstat`), on every protocol: `STAT`
  /// and `LIST` never follow one, so `STA2` is not used here, which does. nil when the path does
  /// not exist.
  public func stat(_ path: String) async throws(ADBError) -> ADBStat? {
    try await perform { () async throws(ADBError) in try await statLocked(path, follow: false) }
  }

  /// `exactSizes: false` is for a caller that needs names and kinds alone: without `ls_v2` it
  /// skips the STA2 per regular file that corrects a size over 4 GB.
  public func list(_ dir: String, exactSizes: Bool = true) async throws(ADBError) -> Listing {
    try await perform { () async throws(ADBError) in try await listLocked(dir, exactSizes) }
  }

  /// Streams the file into `file`. `progress` is told the bytes received and the size `stat`
  /// reported; returning false stops the transfer with `.cancelled` and closes the connection.
  public func receive(
    _ path: String, to file: FileHandle, listedSize: UInt64? = nil, progress: ProgressHandler
  ) async throws(ADBError) -> UInt64 {
    try await perform { () async throws(ADBError) in
      try await receiveLocked(path, to: file, listedSize: listedSize, progress: progress)
    }
  }

  /// Streams `file`, from its current offset to its end, to `path` on the device. The device
  /// applies `mode` (a full st_mode, such as 0o100644) and `mtime`. `progress` stopping the
  /// transfer throws `.cancelled` and closes the connection before the file is finished, so the
  /// caller removes whatever was created at `path`.
  public func send(
    _ file: FileHandle, to path: String, mode: UInt32, mtime: Date, progress: ProgressHandler
  ) async throws(ADBError) {
    try await perform { () async throws(ADBError) in
      try await sendLocked(file, to: path, mode: mode, mtime: mtime, progress: progress)
    }
  }

  /// Ends the connection. Idle, it says `QUIT` first. With a request in flight (possibly wedged
  /// on a device that stopped answering) it cannot wait its turn, so it closes the socket under
  /// the request, which then fails. Either way later calls throw `.connectionClosed`.
  public func quit() async {
    let busy = active
    let wasDead = dead
    dead = true
    if busy { stream.cancel() }
    try? await gate.run { () async throws(ADBError) in
      if !busy, !wasDead { try? await stream.write(Data("QUIT".utf8) + ADBWire.le32(0)) }
      await stream.close()
    }
  }

  /// `follow` reads what a symbolic link points to, as `RECV` opens it; it needs `stat_v2`, and
  /// without it the v1 `STAT` reports the link itself.
  private func statLocked(_ path: String, follow: Bool) async throws(ADBError) -> ADBStat? {
    if statV2 {
      let (error, stat) = try await stat2Locked(path, follow: follow)
      if error == Self.enoent || error == Self.enotdir { return nil }
      guard error == 0 else { throw .failed("stat \(path) failed with errno \(error)") }
      return stat
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

  /// `STA2` (follows a link) or `LST2`: the errno the device reports, and the stat when it is 0.
  private func stat2Locked(_ path: String, follow: Bool) async throws(ADBError)
    -> (errno: UInt32, stat: ADBStat)
  {
    let id = follow ? "STA2" : "LST2"
    try await request(id, path)
    try await expect(id)
    let body = try await stream.read(exactly: Self.stat2Length)
    return (ADBWire.u32(body.prefix(4)), Self.stat2(body))
  }

  public typealias Entry = (name: String, stat: ADBStat)

  /// A folder's entries, and how many names were left out because they are not UTF-8: they
  /// cannot be addressed again, but they are there, so a caller deciding the folder's fate
  /// (deleting it with what it holds) must know.
  public struct Listing: Sendable {
    public var entries: [Entry]
    public let unreadableNames: Int
  }

  private func listLocked(_ dir: String, _ exactSizes: Bool) async throws(ADBError) -> Listing {
    var listing = try await (listV2 ? listWithLis2(dir) : listWithList(dir))
    guard exactSizes, !listV2, statV2 else { return listing }
    // LIST carries 32-bit sizes, so a regular file over 4 GB reads short; STA2 has the truth.
    let prefix = dir.hasSuffix("/") ? dir : dir + "/"
    var unaddressable = 0
    for index in listing.entries.indices where listing.entries[index].stat.isRegular {
      let path = prefix + listing.entries[index].name
      // adbd refuses a request this long, so the entry keeps its 32-bit LIST size.
      guard path.utf8.count <= Self.requestLimit else {
        unaddressable += 1
        continue
      }
      // A file the device will not stat (a folder readable but not searchable) keeps its size.
      let (error, exact) = try await stat2Locked(path, follow: true)
      if error == 0 { listing.entries[index].stat = exact }
    }
    if unaddressable > 0 {
      Self.log.info("listing kept the 32-bit size of \(unaddressable) entries with paths too long")
    }
    return listing
  }

  /// `listedSize` is what the caller checked the Mac's room against: the growth cap runs from
  /// the smaller of it and the size the device reports now, so a stat that answers larger at
  /// download time does not lift it.
  private func receiveLocked(
    _ path: String, to file: FileHandle, listedSize: UInt64?, progress: ProgressHandler
  ) async throws(ADBError) -> UInt64 {
    let total = try await statLocked(path, follow: true)?.size ?? 0
    let capped = min(total, listedSize ?? total)
    try await request("RECV", path)
    var received: UInt64 = 0
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
      switch id {
      case "DATA":
        guard length <= Self.chunkLimit else {
          throw await violation("DATA chunk of \(length) bytes")
        }
        let chunk = try await stream.read(exactly: length)
        do {
          try file.write(contentsOf: chunk)
        } catch {
          await stream.close()
          throw .failed("could not write the received data: \(error.localizedDescription)")
        }
        received += UInt64(length)
        // A file still being written may grow; one that grows without end is not a file. The
        // device reports `total`, so it is never added to: the check cannot overflow.
        guard received <= capped || received - capped <= growthAllowance else {
          throw await violation("receive passed its size of \(capped) bytes")
        }
        guard progress(received, total) else {
          await stream.close()
          throw .cancelled
        }
      case "DONE":
        return received
      case "FAIL":
        throw try await failure(length)
      default:
        throw await violation("unexpected \(id) in a receive")
      }
    }
  }

  private func sendLocked(
    _ file: FileHandle, to path: String, mode: UInt32, mtime: Date, progress: ProgressHandler
  ) async throws(ADBError) {
    let target = "\(path),\(mode)"
    guard target.utf8.count <= Self.requestLimit else { throw .invalidArgument(path) }
    let start: UInt64
    let total: UInt64
    do {
      start = try file.offset()
      total = try file.seekToEnd() - start
      try file.seek(toOffset: start)
    } catch {
      throw .failed("could not size the file to send: \(error.localizedDescription)")
    }
    try await request("SEND", target)
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
    case "FAIL": throw try await failure(length)
    default: throw await violation("unexpected \(id) after a send")
    }
  }
}

// MARK: protocol

extension ADBSync {

  /// 4-byte id, little-endian length, then the path or argument.
  func request(_ id: String, _ argument: String) async throws(ADBError) {
    let payload = Data(argument.utf8)
    guard payload.count <= Self.requestLimit else { throw .invalidArgument(argument) }
    try await stream.write(Data(id.utf8) + ADBWire.le32(UInt32(payload.count)) + payload)
  }

  /// Closes the connection, whose framing can no longer be trusted, and names the problem.
  func violation(_ message: String) async -> ADBError {
    await stream.close()
    return .protocolViolation(message)
  }

  /// The error for a `FAIL` whose message is `length` bytes long.
  func failure(_ length: Int) async throws(ADBError) -> ADBError {
    guard length <= Self.messageLimit else {
      throw await violation("FAIL message of \(length) bytes")
    }
    return .failed(try ADBWire.text(try await stream.read(exactly: length)))
  }

  /// Reads a reply id, turning `FAIL` into its message.
  private func expect(_ id: String) async throws(ADBError) {
    let got = try ADBWire.text(try await stream.read(exactly: 4))
    if got == "FAIL" {
      throw try await failure(Int(ADBWire.u32(try await stream.read(exactly: 4))))
    }
    guard got == id else { throw await violation("expected \(id), got \(got)") }
  }

  /// error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime.
  static let stat2Length = 68

  static func stat2(_ body: Data) -> ADBStat {
    let bytes = Array(body)
    return ADBStat(
      mode: ADBWire.u32(bytes[20..<24]), size: ADBWire.u64(bytes[36..<44]),
      mtime: Date(
        timeIntervalSince1970: TimeInterval(Int64(bitPattern: ADBWire.u64(bytes[52..<60])))))
  }
}
