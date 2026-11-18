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
  private static let nameLimit = 4096
  /// adbd refuses a request longer than this (`path too long`) and ends the session.
  static let requestLimit = 1024
  /// Same bound as a DATA chunk: adbd's FAIL messages are short text.
  private static let messageLimit = 64 * 1024
  /// A hostile peer could stream entries forever; no real folder on a phone comes near this.
  static let defaultEntryLimit = 1_000_000

  private let stream: ADBStream
  private let statV2: Bool
  private let listV2: Bool
  private let entryLimit: Int
  private let gate = OperationGate()
  private var dead = false
  private var active = false

  public init(stream: ADBStream, features: Set<String>) {
    self.init(stream: stream, features: features, entryLimit: Self.defaultEntryLimit)
  }

  init(stream: ADBStream, features: Set<String>, entryLimit: Int) {
    self.stream = stream
    self.statV2 = features.contains("stat_v2")
    self.listV2 = features.contains("ls_v2")
    self.entryLimit = entryLimit
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

  /// nil when the path does not exist.
  public func stat(_ path: String) async throws(ADBError) -> ADBStat? {
    try await perform { () async throws(ADBError) in try await statLocked(path) }
  }

  public func list(_ dir: String) async throws(ADBError) -> Listing {
    try await perform { () async throws(ADBError) in try await listLocked(dir) }
  }

  /// Streams the file into `file`. `progress` is told the bytes received and the size `stat`
  /// reported; returning false stops the transfer with `.cancelled` and closes the connection.
  public func receive(
    _ path: String, to file: FileHandle, progress: ProgressHandler
  ) async throws(ADBError) -> UInt64 {
    try await perform { () async throws(ADBError) in
      try await receiveLocked(path, to: file, progress: progress)
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
    dead = true
    if busy { stream.cancel() }
    try? await gate.run { () async throws(ADBError) in
      if !busy { try? await stream.write(Data("QUIT".utf8) + ADBWire.le32(0)) }
      await stream.close()
    }
  }

  private func statLocked(_ path: String) async throws(ADBError) -> ADBStat? {
    if statV2 {
      try await request("STA2", path)
      try await expect("STA2")
      let body = try await stream.read(exactly: Self.stat2Length)
      let error = ADBWire.u32(body.prefix(4))
      if error == Self.enoent || error == Self.enotdir { return nil }
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

  /// A folder's entries, and how many names were left out because they are not UTF-8: they
  /// cannot be addressed again, but they are there, so a caller deciding the folder's fate
  /// (deleting it with what it holds) must know.
  public struct Listing: Sendable {
    public var entries: [Entry]
    public let unreadableNames: Int
  }

  private func listLocked(_ dir: String) async throws(ADBError) -> Listing {
    var listing = try await (listV2 ? listWithLis2(dir) : listWithList(dir))
    guard !listV2, statV2 else { return listing }
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
      if let exact = try await statLocked(path) { listing.entries[index].stat = exact }
    }
    if unaddressable > 0 {
      Self.log.info("listing kept the 32-bit size of \(unaddressable) entries with paths too long")
    }
    return listing
  }

  private func receiveLocked(
    _ path: String, to file: FileHandle, progress: ProgressHandler
  ) async throws(ADBError) -> UInt64 {
    let total = try await statLocked(path)?.size ?? 0
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
  private func request(_ id: String, _ argument: String) async throws(ADBError) {
    let payload = Data(argument.utf8)
    guard payload.count <= Self.requestLimit else { throw .invalidArgument(argument) }
    try await stream.write(Data(id.utf8) + ADBWire.le32(UInt32(payload.count)) + payload)
  }

  /// Closes the connection, whose framing can no longer be trusted, and names the problem.
  private func violation(_ message: String) async -> ADBError {
    await stream.close()
    return .protocolViolation(message)
  }

  /// The error for a `FAIL` whose message is `length` bytes long.
  private func failure(_ length: Int) async throws(ADBError) -> ADBError {
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
  private static let stat2Length = 68

  private static func stat2(_ body: Data) -> ADBStat {
    let bytes = Array(body)
    return ADBStat(
      mode: ADBWire.u32(bytes[20..<24]), size: ADBWire.u64(bytes[36..<44]),
      mtime: Date(
        timeIntervalSince1970: TimeInterval(Int64(bitPattern: ADBWire.u64(bytes[52..<60])))))
  }

  private func listWithLis2(_ dir: String) async throws(ADBError) -> Listing {
    try await request("LIS2", dir)
    var entries: [Entry] = []
    var unnamed = 0
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      switch id {
      case "DNT2":
        let body = try await stream.read(exactly: Self.stat2Length)
        let name = try await readName()
        guard ADBWire.u32(body.prefix(4)) == 0 else { continue }
        try await add(name, Self.stat2(body), to: &entries, unnamed: &unnamed)
      case "DONE":
        _ = try await stream.read(exactly: Self.stat2Length + 4)
        Self.logUnnamed(unnamed)
        return Listing(entries: entries, unreadableNames: unnamed)
      case "FAIL":
        throw try await failure(Int(ADBWire.u32(try await stream.read(exactly: 4))))
      default:
        throw await violation("unexpected \(id) in a listing")
      }
    }
  }

  private func listWithList(_ dir: String) async throws(ADBError) -> Listing {
    try await request("LIST", dir)
    var entries: [Entry] = []
    var unnamed = 0
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      switch id {
      case "DENT":
        let body = Array(try await stream.read(exactly: 12))
        let stat = ADBStat(
          mode: ADBWire.u32(body[0..<4]), size: UInt64(ADBWire.u32(body[4..<8])),
          mtime: Date(timeIntervalSince1970: TimeInterval(ADBWire.u32(body[8..<12]))))
        try await add(try await readName(), stat, to: &entries, unnamed: &unnamed)
      case "DONE":
        _ = try await stream.read(exactly: 16)
        Self.logUnnamed(unnamed)
        return Listing(entries: entries, unreadableNames: unnamed)
      case "FAIL":
        throw try await failure(Int(ADBWire.u32(try await stream.read(exactly: 4))))
      default:
        throw await violation("unexpected \(id) in a listing")
      }
    }
  }

  /// nil for a name that is not UTF-8: it could not be addressed again, so it is not listed.
  private func readName() async throws(ADBError) -> String? {
    let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
    guard length <= Self.nameLimit else { throw await violation("name of \(length) bytes") }
    return String(bytes: try await stream.read(exactly: length), encoding: .utf8)
  }

  /// Skips `.` and `..`, counts names that are not UTF-8, and enforces the entry cap.
  private func add(
    _ name: String?, _ stat: ADBStat, to entries: inout [Entry], unnamed: inout Int
  ) async throws(ADBError) {
    guard let name else {
      unnamed += 1
      return
    }
    guard name != ".", name != ".." else { return }
    guard entries.count < entryLimit else {
      throw await violation("listing exceeds \(entryLimit) entries")
    }
    entries.append((name, stat))
  }

  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBSync")

  /// A name that is not UTF-8 cannot be addressed again, so it is left out; say so once.
  private static func logUnnamed(_ count: Int) {
    if count > 0 { log.info("listing skipped \(count) names that are not valid UTF-8") }
  }
}
