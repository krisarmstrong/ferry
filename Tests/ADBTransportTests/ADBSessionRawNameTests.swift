import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// A name the device stores in another Unicode form than the NFC one Ferry uses (as macOS and
/// some apps write NFD) stays reachable: every path sent to the device carries the device's own
/// bytes for an existing entry.
struct ADBSessionRawNameTests {
  static let nfd = Array("Cafe\u{301}.txt".utf8)
  static let nfc = Array("Caf\u{E9}.txt".utf8)
  let storage = ADBFixture.storage

  @Test func anNFDFileIsListedDownloadedRenamedAndDeleted() async throws {
    let device = FakeAndroid()
    device.addRaw("/", name: Self.nfd, node: .file(Data("nfd".utf8), mtime: 7))
    device.addRaw("/", name: Array("Other\u{301}".utf8), node: .file(Data("o".utf8), mtime: 7))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = try RemotePath("/Caf\u{E9}.txt")
    try await ADBFixture.withSession(device) { session in
      let listed = try await session.list(.root, in: storage)
      #expect(listed.map(\.path).contains(path))
      #expect(try await session.item(at: path, in: storage).size == 3)
      let file = folder.appending(path: "x")
      try await session.download(
        path, in: storage, to: file, replacing: false, progress: ADBFixture.noProgress)
      #expect(try Data(contentsOf: file) == Data("nfd".utf8))
      _ = try await session.rename(path, to: "Menu.txt", in: storage)
      #expect(device.rawNames(in: "/").contains(Array("Menu.txt".utf8)))
      #expect(!device.rawNames(in: "/").contains(Self.nfd))
      try await session.delete(RemotePath("/Other\u{301}"), in: storage)
    }
    #expect(device.rawNames(in: "/") == [Array("Menu.txt".utf8)])
  }

  /// A folder named in NFD is walked into with its own bytes.
  @Test func anNFDFolderIsServedWithItsContents() async throws {
    let device = FakeAndroid()
    device.addRaw("/", name: Array("Cafe\u{301}".utf8), node: .folder(mtime: 1))
    device.addRaw("/Cafe\u{301}", name: Array("a.txt".utf8), node: .file(Data("a".utf8), mtime: 1))
    let folder = try RemotePath("/Caf\u{E9}")
    try await ADBFixture.withSession(device) { session in
      let items = try await session.list(folder, in: storage)
      #expect(items.map(\.path) == [try folder.appending("a.txt")])
      _ = try await session.makeFolder(folder.appending("New"), in: storage)
      try await session.delete(folder, in: storage)
    }
    #expect(device.rawNames(in: "/").isEmpty)
  }

  /// NFC and NFD spellings of one name are one path to Ferry. The NFC entry, whose bytes are its
  /// path, is shown; its twin is left out, and so counts as unseen for a checked delete.
  @Test func ofNFCAndNFDTwinsTheNFCOneIsShown() async throws {
    let device = FakeAndroid()
    device.addFolder("/F")
    device.addRaw("/F", name: Self.nfd, node: .file(Data("nfd!".utf8), mtime: 1))
    device.addRaw("/F", name: Self.nfc, node: .file(Data("nfc".utf8), mtime: 1))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let top = try RemotePath("/F")
    let path = try top.appending("Caf\u{E9}.txt")
    let upload = try ADBFixture.localFile(Data("new".utf8))
    defer { try? FileManager.default.removeItem(at: upload) }
    try await ADBFixture.withSession(device) { session in
      let listed = try await session.list(top, in: storage)
      #expect(listed.map(\.path) == [path])
      #expect(listed.first?.size == 3)
      let file = folder.appending(path: "x")
      try await session.download(
        path, in: storage, to: file, replacing: false, progress: ADBFixture.noProgress)
      #expect(try Data(contentsOf: file) == Data("nfc".utf8))
      await #expect(throws: TransportError.alreadyExists(path)) {
        _ = try await session.upload(
          from: upload, to: path, in: storage, progress: ADBFixture.noProgress)
      }
      let checked = [try await session.item(at: top, in: storage)] + listed
      await #expect(throws: TransportError.directoryNotEmpty(top)) {
        try await session.delete(top, in: storage, expecting: checked)
      }
    }
    #expect(
      device.rawNames(in: "/F") == [Self.nfd, Self.nfc].sorted { $0.lexicographicallyPrecedes($1) })
  }

  /// A name that starts with a byte order mark keeps it: Foundation's UTF-8 decoding drops a
  /// leading `EF BB BF`, which would list `a` and then act on the file named `a`.
  @Test func aLeadingByteOrderMarkStaysInTheName() async throws {
    let device = FakeAndroid()
    device.addRaw("/", name: [0xEF, 0xBB, 0xBF, 0x61], node: .file(Data("bom".utf8), mtime: 1))
    device.addFile("/a", Data("plain".utf8))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = try RemotePath("/\u{FEFF}a")
    try await ADBFixture.withSession(device) { session in
      let listed = try await session.list(.root, in: storage)
      #expect(Set(listed.map(\.path)) == [path, try RemotePath("/a")])
      #expect(try await session.item(at: path, in: storage).size == 3)
      let file = folder.appending(path: "x")
      try await session.download(
        path, in: storage, to: file, replacing: false, progress: ADBFixture.noProgress)
      #expect(try Data(contentsOf: file) == Data("bom".utf8))
      try await session.delete(path, in: storage)
    }
    #expect(device.rawNames(in: "/") == [Array("a".utf8)])
  }

  // MARK: Exact names

  /// Case-insensitive storage would find `A.txt` for `a.txt`; Ferry acts only on the exact name.
  @Test func aCaseVariantIsNotTheItemAsked() async throws {
    let device = FakeAndroid()
    device.addFile("/A.txt", Data("upper".utf8))
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let lower = try RemotePath("/a.txt")
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.notFound(lower)) {
        _ = try await session.item(at: lower, in: storage)
      }
      await #expect(throws: TransportError.notFound(lower)) {
        try await session.download(
          lower, in: storage, to: folder.appending(path: "a.txt"), replacing: false,
          progress: ADBFixture.noProgress)
      }
      await #expect(throws: TransportError.notFound(lower)) {
        try await session.delete(lower, in: storage)
      }
      await #expect(throws: TransportError.notFound(lower)) {
        _ = try await session.move(lower, toFolder: .root, in: storage)
      }
    }
    #expect(device.contents("/A.txt") == Data("upper".utf8))
    #expect(device.changes.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  // MARK: Cost

  /// Only listings that report sizes re-read each file on a device without `ls_v2`: the
  /// session's own name checks list names alone.
  @Test func aSafeWriterWriteIntoALargeFolderStatsEachFileOnce() async throws {
    let device = FakeAndroid()
    device.addFolder("/Big")
    for index in 0..<100 { device.addFile("/Big/f\(index).txt", Data("x".utf8)) }
    let file = try ADBFixture.localFile(Data("new".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    try await ADBFixture.withSession(device) { session in
      _ = try await SafeWriter(session: session, backups: .scratch()).write(
        from: file, to: RemotePath("/Big/new.txt"), in: storage, replacing: false,
        progress: ADBFixture.noProgress)
    }
    let stats = device.syncRequests.filter { $0.id == "STA2" }.count
    // SafeWriter's own existence check lists the folder with sizes: 100. The rest are a
    // handful of single stats, where re-statting every name check would add 200 more.
    #expect(stats <= 115)
    #expect(device.contents("/Big/new.txt") == Data("new".utf8))
  }
}
