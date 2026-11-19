import Foundation
import os

/// Reading a folder over `LIS2` (with `ls_v2`) or `LIST`.
extension ADBSync {
  func listWithLis2(_ dir: String) async throws(ADBError) -> Listing {
    try await request("LIS2", dir)
    var entries: [Entry] = []
    var unnamed = 0
    var failed = 0
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      switch id {
      case "DNT2":
        let body = try await stream.read(exactly: Self.stat2Length)
        let name = try await readName()
        let stat = ADBWire.u32(body.prefix(4)) == 0 ? Self.stat2(body) : nil
        try await add(name, stat, to: &entries, unnamed: &unnamed, failed: &failed)
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

  func listWithList(_ dir: String) async throws(ADBError) -> Listing {
    try await request("LIST", dir)
    var entries: [Entry] = []
    var unnamed = 0
    var failed = 0
    while true {
      let id = try ADBWire.text(try await stream.read(exactly: 4))
      switch id {
      case "DENT":
        let body = Array(try await stream.read(exactly: 12))
        let stat = ADBStat(
          mode: ADBWire.u32(body[0..<4]), size: UInt64(ADBWire.u32(body[4..<8])),
          mtime: Date(timeIntervalSince1970: TimeInterval(ADBWire.u32(body[8..<12]))))
        try await add(try await readName(), stat, to: &entries, unnamed: &unnamed, failed: &failed)
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
  /// `String(validating:)` keeps every scalar, a leading byte order mark included, where
  /// Foundation's UTF-8 decoding drops one and so would name another file.
  private func readName() async throws(ADBError) -> String? {
    let length = Int(ADBWire.u32(try await stream.read(exactly: 4)))
    guard length <= Self.nameLimit else { throw await violation("name of \(length) bytes") }
    return String(validating: try await stream.read(exactly: length), as: UTF8.self)
  }

  /// Skips `.` and `..`, counts names that are not UTF-8 and entries the device could not stat
  /// (`stat` nil), and enforces the entry cap on all of them: a device could stream left-out
  /// entries forever too.
  private func add(
    _ name: String?, _ stat: ADBStat?, to entries: inout [Entry], unnamed: inout Int,
    failed: inout Int
  ) async throws(ADBError) {
    guard name != ".", name != ".." else { return }
    guard entries.count + unnamed + failed < entryLimit else {
      throw await violation("listing exceeds \(entryLimit) entries")
    }
    guard let name else {
      unnamed += 1
      return
    }
    guard let stat else {
      failed += 1
      return
    }
    entries.append((name, stat))
  }

  static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBSync")

  /// A name that is not UTF-8 cannot be addressed again, so it is left out; say so once.
  private static func logUnnamed(_ count: Int) {
    if count > 0 { log.info("listing skipped \(count) names that are not valid UTF-8") }
  }
}
