import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// `SafeWriter`, unchanged, on the real `ADBSession`: its write rules checked against sync
/// transfers and shell renames rather than the fake session's path tree.
struct SafeWriterOverADBSessionTests {
  let storage = ADBFixture.storage

  func write(
    _ data: Data, to target: String, on session: ADBSession, replacing: Bool,
    in storage: StorageID = ADBFixture.storage,
    progress: @escaping ProgressHandler = ADBFixture.noProgress
  ) async throws -> RemoteItem {
    let file = try ADBFixture.localFile(data)
    defer { try? FileManager.default.removeItem(at: file) }
    return try await SafeWriter(session: session, backups: .scratch()).write(
      from: file, to: ADBFixture.path(target), in: storage, replacing: replacing,
      progress: progress)
  }

  @Test func uploadsToAPartialThenRenames() async throws {
    let device = FakeAndroid()
    let item = try await ADBFixture.withSession(device) { session in
      try await write(Data("new".utf8), to: "/a.txt", on: session, replacing: false)
    }
    #expect(item.path == (try ADBFixture.path("/a.txt")) && item.size == 3)
    #expect(device.tree == ["/a.txt"])
    #expect(device.contents("/a.txt") == Data("new".utf8))
    let sent = device.syncRequests.filter { $0.id == "SEND" }.map(\.path)
    #expect(sent.count == 1)
    #expect(
      sent.first?.hasPrefix(FakeAndroid.internalRoot + "/" + SafeWriter.partialPrefix) == true)
    #expect(device.changes.map(\.first) == ["mv"])
  }

  /// Upload, set the old file aside, rename the new one into place, then delete the old one.
  @Test func replacingDeletesTheOldFileOnlyOnceTheNewOneIsInPlace() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("old".utf8))
    _ = try await ADBFixture.withSession(device) { session in
      try await write(Data("new".utf8), to: "/a.txt", on: session, replacing: true)
    }
    let commands = device.changes
    #expect(commands.map(\.first) == ["mv", "mv", "rm"])
    #expect(commands.first?.last?.contains(SafeWriter.backupPrefix) == true)
    #expect(commands[1].last == FakeAndroid.internalRoot + "/a.txt")
    #expect(device.tree == ["/a.txt"])
    #expect(device.contents("/a.txt") == Data("new".utf8))
  }

  @Test(arguments: [false, true])
  func aFolderIsNeverReplaced(replacing: Bool) async throws {
    let device = FakeAndroid()
    device.addFolder("/A")
    device.addFile("/A/b.txt", Data("keep".utf8))
    await #expect(throws: TransportError.alreadyExists(try ADBFixture.path("/A"))) {
      try await ADBFixture.withSession(device) { session in
        _ = try await write(Data("new".utf8), to: "/A", on: session, replacing: replacing)
      }
    }
    #expect(device.tree == ["/A", "/A/b.txt"])
  }

  @Test func replacingACaseVariantReplacesIt() async throws {
    let device = FakeAndroid()
    device.addFile("/FOO.txt", Data("old".utf8))
    _ = try await ADBFixture.withSession(device) { session in
      try await write(Data("new".utf8), to: "/foo.txt", on: session, replacing: true)
    }
    #expect(device.tree == ["/foo.txt"])
    #expect(device.contents("/foo.txt") == Data("new".utf8))
  }

  @Test func aCancelledWriteLeavesNothingVisible() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("old".utf8))
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.cancelled) {
        _ = try await write(
          Data(count: 100_000), to: "/a.txt", on: session, replacing: true
        ) { _, _ in false }
      }
      let visible = try await SafeWriter(session: session, backups: .scratch()).visibleList(
        .root, in: storage)
      #expect(visible.map(\.path) == [try ADBFixture.path("/a.txt")])
    }
    #expect(device.contents("/a.txt") == Data("old".utf8))
    // adbd unlinks the cancelled upload once its connection ends.
    await device.waitUntilNone(.connections)
    #expect(device.tree == ["/a.txt"])
  }

  @Test func listingHidesAndReapsAnAbandonedPartial() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.addFile("/.ferry-partial-X", Data("p".utf8))
    let visible = try await ADBFixture.withSession(device) { session in
      try await SafeWriter(session: session, backups: .scratch()).visibleList(.root, in: storage)
    }
    #expect(visible.map(\.path) == [try ADBFixture.path("/a.txt")])
    #expect(device.tree == ["/a.txt"])
  }

  @Test func unknownStorageIsRejectedBeforeUpload() async throws {
    let device = FakeAndroid()
    let unknown = StorageID(device: ADBFixture.deviceID, key: "volume:FFFF-0000")
    await #expect(throws: TransportError.storageNotFound(unknown.key)) {
      try await ADBFixture.withSession(device) { session in
        _ = try await write(
          Data("x".utf8), to: "/a.txt", on: session, replacing: false, in: unknown)
      }
    }
    #expect(!device.syncRequests.contains { $0.id == "SEND" })
  }
}
