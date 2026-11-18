import Foundation

@testable import ADBTransport

/// Scripting helpers for the sync service and shell_v2 on `FakeADBServer`.
extension FakeADBServer.Peer {
  /// Answers the `host:transport:` select and the service start, as the server does for `connect`.
  func accept(service: String) async throws {
    _ = try await request()
    try await okay()
    let started = try await request()
    guard started == service else { throw ScriptError.unexpected(started) }
    try await okay()
  }

  /// One sync request header: the 4-character id and its little-endian length field.
  func syncHeader() async throws -> (id: String, length: UInt32) {
    let id = try ADBWire.text(try await stream.read(exactly: 4))
    let length = Self.u32(try await stream.read(exactly: 4))
    return (id, length)
  }

  /// A request that carries a path, such as `STA2` or `LIS2`.
  func syncPathRequest() async throws -> (id: String, path: String) {
    let (id, length) = try await syncHeader()
    return (id, try ADBWire.text(try await stream.read(exactly: Int(length))))
  }

  func raw(_ data: Data) async throws { try await stream.write(data) }

  static func u32(_ data: Data) -> UInt32 {
    data.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
  }

  static func le32(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
  }

  static func le64(_ value: UInt64) -> Data {
    Data((0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
  }

  /// `STAT`: mode, size, mtime, each 32 bits.
  static func stat(mode: UInt32, size: UInt32, mtime: UInt32) -> Data {
    Data("STAT".utf8) + le32(mode) + le32(size) + le32(mtime)
  }

  /// The body shared by `STA2` and `DNT2`: error, dev, ino, mode, nlink, uid, gid, size, three times.
  static func stat2Body(error: UInt32 = 0, mode: UInt32, size: UInt64, mtime: Int64) -> Data {
    var body = le32(error) + le64(0) + le64(0)
    body += le32(mode) + le32(1) + le32(0) + le32(0)
    body += le64(size) + le64(0) + le64(UInt64(bitPattern: mtime)) + le64(0)
    return body
  }

  static func sta2(error: UInt32 = 0, mode: UInt32, size: UInt64, mtime: Int64) -> Data {
    Data("STA2".utf8) + stat2Body(error: error, mode: mode, size: size, mtime: mtime)
  }

  static func dnt2(name: String, mode: UInt32, size: UInt64, mtime: Int64) -> Data {
    Data("DNT2".utf8) + stat2Body(mode: mode, size: size, mtime: mtime)
      + le32(UInt32(name.utf8.count)) + Data(name.utf8)
  }

  static func dent(name: String, mode: UInt32, size: UInt32, mtime: UInt32) -> Data {
    Data("DENT".utf8) + le32(mode) + le32(size) + le32(mtime) + le32(UInt32(name.utf8.count))
      + Data(name.utf8)
  }

  /// The list terminator: `DONE` with a zeroed entry (v1 body is 16 bytes, v2 is 72).
  static func listDone(extended: Bool) -> Data {
    Data("DONE".utf8) + Data(count: extended ? 72 : 16)
  }

  static func data(_ bytes: Data) -> Data {
    Data("DATA".utf8) + le32(UInt32(bytes.count)) + bytes
  }

  static func done(_ value: UInt32 = 0) -> Data { Data("DONE".utf8) + le32(value) }

  static func fail(_ message: String) -> Data {
    Data("FAIL".utf8) + le32(UInt32(message.utf8.count)) + Data(message.utf8)
  }

  static func shellPacket(_ id: UInt8, _ payload: Data) -> Data {
    Data([id]) + le32(UInt32(payload.count)) + payload
  }
}

enum ScriptError: Error { case unexpected(String) }

/// A connected `ADBSync` against a scripted fake, and scratch files for the transfer tests.
enum SyncFixture {
  typealias Peer = FakeADBServer.Peer

  static func sync(
    _ features: Set<String>, script: @escaping @Sendable (Peer) async throws -> Void
  ) async throws -> (ADBSync, FakeADBServer) {
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      try await script(peer)
    }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let stream = try await host.connect("S", service: "sync:")
    return (ADBSync(stream: stream, features: features), server)
  }

  static func scratchFile(_ bytes: Data? = nil) throws -> (URL, FileHandle) {
    let url = FileManager.default.temporaryDirectory.appending(path: "ferry-sync-\(UUID()).bin")
    FileManager.default.createFile(atPath: url.path, contents: bytes)
    return (url, try FileHandle(forUpdating: url))
  }
}
