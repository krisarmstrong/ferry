import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Upload, folders, rename and move on `ADBSession`, against `MTPSession`'s contracts.
struct ADBSessionWriteTests {
  let storage = ADBFixture.storage

  func path(_ string: String) throws -> RemotePath { try ADBFixture.path(string) }

  func upload(
    _ data: Data, to target: String, on session: ADBSession, modified: Date? = nil,
    progress: @escaping ProgressHandler = ADBFixture.noProgress
  ) async throws -> RemoteItem {
    let file = try ADBFixture.localFile(data, modified: modified)
    defer { try? FileManager.default.removeItem(at: file) }
    return try await session.upload(from: file, to: path(target), in: storage, progress: progress)
  }

  // MARK: Upload

  @Test func uploadStoresTheFileWithItsMacDate() async throws {
    let device = FakeAndroid()
    device.addFolder("/Download")
    let date = Date(timeIntervalSince1970: 1_650_000_123)
    let item = try await ADBFixture.withSession(device) { session in
      try await upload(Data("hello".utf8), to: "/Download/a.txt", on: session, modified: date)
    }
    #expect(
      item == RemoteItem(path: try path("/Download/a.txt"), kind: .file, size: 5, modified: date))
    #expect(device.node("/Download/a.txt") == .file(Data("hello".utf8), mtime: 1_650_000_123))
  }

  /// adbd's SEND replaces a file and creates missing folders: neither may happen.
  @Test func uploadRefusesAnExistingNameOrCaseVariantWithoutSending() async throws {
    let device = FakeAndroid()
    device.addFile("/A.txt", Data("old".utf8))
    let existing = try path("/A.txt")
    try await ADBFixture.withSession(device) { session in
      for name in ["/A.txt", "/a.txt"] {
        await #expect(throws: TransportError.alreadyExists(existing)) {
          _ = try await upload(Data("new".utf8), to: name, on: session)
        }
      }
    }
    #expect(device.contents("/A.txt") == Data("old".utf8))
    #expect(!device.syncRequests.contains { $0.id == "SEND" })
  }

  @Test func uploadIntoAMissingFolderIsNotFoundAndMakesNoFolder() async throws {
    let device = FakeAndroid()
    await #expect(throws: TransportError.notFound(try path("/missing"))) {
      try await ADBFixture.withSession(device) { session in
        _ = try await upload(Data("x".utf8), to: "/missing/a.txt", on: session)
      }
    }
    #expect(device.tree.isEmpty)
  }

  @Test func aCancelledUploadLeavesNoFile() async throws {
    let device = FakeAndroid()
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.cancelled) {
        _ = try await upload(Data(count: 100_000), to: "/a.bin", on: session) { _, _ in false }
      }
    }
    #expect(try await ADBFixture.eventually { device.tree.isEmpty })
  }

  @Test func aFullDeviceIsInsufficientSpace() async throws {
    let device = FakeAndroid()
    device.failNextSend("write failed: No space left on device")
    await #expect(throws: TransportError.insufficientSpace(needed: 0, free: 0)) {
      try await ADBFixture.withSession(device) { session in
        _ = try await upload(Data(count: 10), to: "/a.bin", on: session)
      }
    }
    #expect(device.tree.isEmpty)
  }

  // MARK: Folders

  @Test func makeFolderCreatesIt() async throws {
    let device = FakeAndroid()
    let item = try await ADBFixture.withSession(device) { session in
      try await session.makeFolder(path("/New"), in: storage)
    }
    #expect(item.path == (try path("/New")) && item.kind == .folder)
    #expect(device.tree == ["/New"])
    #expect(device.changes == [["mkdir", "--", "/storage/emulated/0/New"]])
  }

  @Test(arguments: ["/Photos", "/photos", "/"])
  func makeFolderRefusesAnExistingNameWithoutRunningMkdir(_ name: String) async throws {
    let device = FakeAndroid()
    device.addFolder("/Photos")
    let existing = name == "/" ? RemotePath.root : try path("/Photos")
    await #expect(throws: TransportError.alreadyExists(existing)) {
      try await ADBFixture.withSession(device) {
        _ = try await $0.makeFolder(path(name), in: storage)
      }
    }
    #expect(device.changes.isEmpty)
  }

  @Test func makeFolderInAMissingFolderIsNotFound() async throws {
    await #expect(throws: TransportError.notFound(try path("/none"))) {
      try await ADBFixture.withSession(FakeAndroid()) {
        _ = try await $0.makeFolder(path("/none/New"), in: storage)
      }
    }
  }

  // MARK: Rename

  @Test func renameRunsMvWithoutClobbering() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    let item = try await ADBFixture.withSession(device) { session in
      try await session.rename(path("/a.txt"), to: "b.txt", in: storage)
    }
    #expect(item.path == (try path("/b.txt")) && item.size == 1)
    #expect(device.tree == ["/b.txt"])
    #expect(
      device.changes == [
        ["mv", "-n", "--", "/storage/emulated/0/a.txt", "/storage/emulated/0/b.txt"]
      ])
  }

  @Test func renameOntoACaseVariantIsRefused() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.addFile("/B.txt", Data("b".utf8))
    await #expect(throws: TransportError.alreadyExists(try path("/B.txt"))) {
      try await ADBFixture.withSession(device) {
        _ = try await $0.rename(path("/a.txt"), to: "b.txt", in: storage)
      }
    }
    #expect(device.tree == ["/B.txt", "/a.txt"])
    #expect(device.changes.isEmpty)
  }

  /// On case-insensitive storage `mv a A` is a no-op that reports success, and a folder would be
  /// moved into itself: a case-only rename goes through a temporary name.
  @Test(arguments: [false, true])
  func aCaseOnlyRenameTakesEffect(folder: Bool) async throws {
    let device = FakeAndroid()
    if folder {
      device.addFolder("/photos")
      device.addFile("/photos/x.jpg", Data("x".utf8))
    } else {
      device.addFile("/photos", Data("p".utf8))
    }
    let item = try await ADBFixture.withSession(device) { session in
      try await session.rename(path("/photos"), to: "Photos", in: storage)
    }
    #expect(item.path == (try path("/Photos")))
    #expect(device.tree == (folder ? ["/Photos", "/Photos/x.jpg"] : ["/Photos"]))
  }

  @Test func renameToItsOwnNameChangesNothing() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    let item = try await ADBFixture.withSession(device) { session in
      try await session.rename(path("/a.txt"), to: "a.txt", in: storage)
    }
    #expect(item.path == (try path("/a.txt")))
    #expect(device.changes.isEmpty)
  }

  @Test func renamingAMissingItemIsNotFound() async throws {
    await #expect(throws: TransportError.notFound(try path("/none"))) {
      try await ADBFixture.withSession(FakeAndroid()) {
        _ = try await $0.rename(path("/none"), to: "b", in: storage)
      }
    }
  }

  /// `mv -n` leaves an existing target alone and still exits 0: the session sees the source
  /// still there and reports the clash instead of a rename that did not happen.
  @Test func aTargetThatAppearsBeforeTheMvIsNotOverwritten() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.beforeNextShell("mv") { $0.addFile("/b.txt", Data("theirs".utf8)) }
    await #expect(throws: TransportError.alreadyExists(try path("/b.txt"))) {
      try await ADBFixture.withSession(device) {
        _ = try await $0.rename(path("/a.txt"), to: "b.txt", in: storage)
      }
    }
    #expect(device.contents("/a.txt") == Data("a".utf8))
    #expect(device.contents("/b.txt") == Data("theirs".utf8))
  }

  // MARK: Move

  @Test func moveTakesAFolderWithItsContents() async throws {
    let device = FakeAndroid()
    device.addFolder("/A")
    device.addFile("/A/x.txt", Data("x".utf8))
    device.addFolder("/B")
    let item = try await ADBFixture.withSession(device) { session in
      try await session.move(path("/A"), toFolder: path("/B"), in: storage)
    }
    #expect(item.path == (try path("/B/A")) && item.kind == .folder)
    #expect(device.tree == ["/B", "/B/A", "/B/A/x.txt"])
    #expect(
      device.changes == [["mv", "-n", "--", "/storage/emulated/0/A", "/storage/emulated/0/B/A"]])
  }

  @Test func moveOntoACaseVariantIsRefused() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.addFolder("/B")
    device.addFile("/B/A.TXT", Data("b".utf8))
    await #expect(throws: TransportError.alreadyExists(try path("/B/A.TXT"))) {
      try await ADBFixture.withSession(device) {
        _ = try await $0.move(path("/a.txt"), toFolder: path("/B"), in: storage)
      }
    }
    #expect(device.changes.isEmpty)
  }

  @Test(arguments: [("/none", "/B", "/none"), ("/a.txt", "/none", "/none")])
  func moveWithAMissingEndIsNotFound(_ source: String, _ folder: String, _ missing: String)
    async throws
  {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    device.addFolder("/B")
    await #expect(throws: TransportError.notFound(try path(missing))) {
      try await ADBFixture.withSession(device) {
        _ = try await $0.move(path(source), toFolder: path(folder), in: storage)
      }
    }
    #expect(device.tree == ["/B", "/a.txt"])
  }
}
