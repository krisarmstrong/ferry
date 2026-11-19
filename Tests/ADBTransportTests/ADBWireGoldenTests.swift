import Foundation
import Testing

@testable import ADBTransport

/// The wire bytes, written out by hand: the fakes frame with the production encoder, so a
/// framing mistake made the same way in both would pass every other test.
struct ADBWireGoldenTests {
  @Test func aHostRequestIsFourHexDigitsOfLengthThenThePayload() throws {
    #expect(
      Array(try ADBWire.frame("host:version"))
        == [0x30, 0x30, 0x30, 0x63]  // "000c"
        + [0x68, 0x6F, 0x73, 0x74, 0x3A, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E])
    #expect(Array(try ADBWire.frame("")) == [0x30, 0x30, 0x30, 0x30])
  }

  /// One STAT, LIST and RECV over sync v1, every byte checked and every reply literal.
  @Test(.timeLimit(.minutes(1)))
  func aSyncStatListAndReceiveExchange() async throws {
    let mismatches = Box<[String]>([])
    let server = try await FakeADBServer.start { peer in
      try await peer.accept(service: "sync:")
      func expect(_ bytes: [UInt8], _ what: String) async throws {
        let got = Array(try await peer.stream.read(exactly: bytes.count))
        if got != bytes { await mismatches.set(await mismatches.value + [what]) }
      }
      // STAT "/a" → mode 0o100644, size 3, mtime 1.
      try await expect([0x53, 0x54, 0x41, 0x54, 0x02, 0x00, 0x00, 0x00, 0x2F, 0x61], "STAT")
      try await peer.raw(
        Data([
          0x53, 0x54, 0x41, 0x54, 0xA4, 0x81, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
          0x01, 0x00, 0x00, 0x00,
        ]))
      // LIST "/d" → one DENT "f" (mode 0o100644, size 3, mtime 1), then DONE.
      try await expect([0x4C, 0x49, 0x53, 0x54, 0x02, 0x00, 0x00, 0x00, 0x2F, 0x64], "LIST")
      try await peer.raw(
        Data([
          0x44, 0x45, 0x4E, 0x54, 0xA4, 0x81, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
          0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x66,
        ])
          + Data([0x44, 0x4F, 0x4E, 0x45] + [UInt8](repeating: 0, count: 16)))
      // RECV "/a": the size first (STAT), then the data and DONE.
      try await expect([0x53, 0x54, 0x41, 0x54, 0x02, 0x00, 0x00, 0x00, 0x2F, 0x61], "STAT 2")
      try await peer.raw(
        Data([
          0x53, 0x54, 0x41, 0x54, 0xA4, 0x81, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
          0x01, 0x00, 0x00, 0x00,
        ]))
      try await expect([0x52, 0x45, 0x43, 0x56, 0x02, 0x00, 0x00, 0x00, 0x2F, 0x61], "RECV")
      try await peer.raw(
        Data([
          0x44, 0x41, 0x54, 0x41, 0x03, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63,
          0x44, 0x4F, 0x4E, 0x45, 0x00, 0x00, 0x00, 0x00,
        ]))
      _ = try? await peer.stream.read(exactly: 1)
    }
    defer { server.stop() }
    let host = ADBHost(port: server.port, locator: ADBHostTests.noAdb)
    let sync = ADBSync(
      stream: try await host.connect("S", service: "sync:", transportID: nil), features: [])

    let stat = try #require(try await sync.stat("/a"))
    #expect(stat.mode == 0o100644 && stat.size == 3)
    #expect(stat.mtime == Date(timeIntervalSince1970: 1))
    let listing = try await sync.list("/d")
    #expect(listing.entries.map(\.name) == ["f"])
    #expect(listing.entries.first?.stat.size == 3)
    let (url, handle) = try SyncFixture.scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await sync.receive("/a", to: handle, progress: { _, _ in true }) == 3)
    #expect(try Data(contentsOf: url) == Data([0x61, 0x62, 0x63]))
    #expect(await mismatches.value.isEmpty)
  }
}
