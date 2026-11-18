import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// libmtp keeps the object info it first loads for an ID, so only a listing (which reads the
/// folder's object IDs from the device) can tell that the device dropped, replaced or moved an
/// object. Every operation that changes the device, and every read that feeds a decision about
/// a change (`item(at:)`), lists the item's folder fresh and acts on the object found there. A
/// download, which changes nothing on the device, resolves from the cached listing and lists
/// again only if that fails. (The stub keeps object info as libmtp does.)
struct MTPSessionCacheTests {
  private let storage = SessionFixture.storage

  /// `/Big` holding `count` one-byte files, listed once, and the listings that took.
  private func bigFolder(_ count: Int) async throws -> (StubMTPDevice, MTPSession) {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("Big", parent: SessionFixture.root)
    for index in 0..<count {
      await device.addFile("f\(index).txt", parent: folder, data: Data("x".utf8))
    }
    let session = MTPSession(device: device, scratch: TestScratch.root)
    _ = try await session.list(SessionFixture.path("/Big"), in: storage)
    return (device, session)
  }

  @Test func downloadingManyFilesFromALargeFolderListsItNoMoreTimes() async throws {
    let (device, session) = try await bigFolder(1_000)
    let listed = await device.listCount
    let folder = try TestScratch.folder("downloads")
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<100 {
      try await session.download(
        SessionFixture.path("/Big/f\(index).txt"), in: storage,
        to: folder.appending(path: "f\(index)"), replacing: false,
        progress: SessionFixture.noProgress)
    }

    let relisted = await device.listCount - listed
    #expect(relisted == 0, "listed the folder \(relisted) more times")
  }

  /// Correctness over speed: each delete lists every folder on the way from the root, to act on
  /// what is there now.
  @Test func eachDeleteListsThePathFromTheRoot() async throws {
    let (device, session) = try await bigFolder(100)
    let listed = await device.listCount

    for index in 0..<10 {
      try await session.delete(SessionFixture.path("/Big/f\(index).txt"), in: storage)
    }

    // The root and `/Big`, for each delete.
    #expect(await device.listCount - listed == 20)
    #expect(
      await device.children(of: try #require(await device.objectID(named: "Big"))).count == 90)
  }

  @Test func aFileTheDeviceMovedElsewhereIsNotDeletedThere() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("a".utf8))
    let other = await device.addFolder("Other", parent: SessionFixture.root)
    let session = MTPSession(device: device, scratch: TestScratch.root)
    _ = try await session.list(.root, in: storage)
    await device.moveObject(id, to: other)

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      try await session.delete(SessionFixture.path("/a.txt"), in: storage)
    }
    #expect(await device.children(of: other) == ["a.txt"])
  }

  /// The cached root listing still names `/A` by the ID of a folder the device has since moved
  /// into `/B`: resolving through it would delete `/B/A/x.txt`.
  @Test func aFileInAFolderTheDeviceMovedIsNotDeletedThere() async throws {
    let device = SessionFixture.makeDevice()
    let folderA = await device.addFolder("A", parent: SessionFixture.root)
    let folderB = await device.addFolder("B", parent: SessionFixture.root)
    await device.addFile("x.txt", parent: folderA, data: Data("x".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    _ = try await session.list(.root, in: storage)
    _ = try await session.list(SessionFixture.path("/A"), in: storage)
    await device.moveObject(folderA, to: folderB)

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/A/x.txt"))) {
      try await session.delete(SessionFixture.path("/A/x.txt"), in: storage)
    }
    #expect(await device.children(of: folderA) == ["x.txt"])
  }

  /// Android's MTP server gives a file an app renamed a new object ID: to libmtp it is one
  /// object gone and another added.
  @Test func aFileTheDeviceRenamedIsNotDeletedUnderItsNewName() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("a".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(id)
    await device.addFile("b.txt", parent: SessionFixture.root, data: Data("a".utf8))

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      try await session.delete(SessionFixture.path("/a.txt"), in: storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["b.txt"])
  }
}

struct MTPSessionStaleObjectInfoTests {
  private let storage = SessionFixture.storage

  private func listedThenReplaced() async throws -> (StubMTPDevice, MTPSession) {
    let device = SessionFixture.makeDevice()
    let old = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(old)
    await device.addFile(
      "a.txt", parent: SessionFixture.root, data: Data("replaced on the unit".utf8))
    return (device, session)
  }

  /// What a save's or a delete's base check reads: the object the device has now.
  @Test func anItemTheDeviceReplacedIsReadAsTheNewObject() async throws {
    let (_, session) = try await listedThenReplaced()

    let item = try await session.item(at: SessionFixture.path("/a.txt"), in: storage)

    #expect(item.size == UInt64("replaced on the unit".utf8.count))
  }

  /// The save checked the old file; the device replaced it before the write: nothing is
  /// overwritten.
  @Test func aWriteExpectingTheOldFileKeepsTheDevicesNewOne() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = try await session.item(at: SessionFixture.path("/a.txt"), in: storage)
    let old = try #require(await device.objectID(named: "a.txt"))
    await device.removeObject(old)
    await device.addFile(
      "a.txt", parent: SessionFixture.root, data: Data("replaced on the unit".utf8))
    let local = try SessionFixture.localFile(Data("mac edit".utf8))
    defer { try? FileManager.default.removeItem(at: local) }

    await #expect(throws: TransportError.changedOnDevice(try SessionFixture.path("/a.txt"))) {
      _ = try await SafeWriter(session: session).write(
        from: local, to: SessionFixture.path("/a.txt"), in: storage, replacing: true,
        expecting: checked, progress: SessionFixture.noProgress)
    }
    let left = await device.objects.values.map { String(bytes: $0.data, encoding: .utf8) }
    #expect(left == ["replaced on the unit"])
  }

  /// The device swaps the file while the new contents go up: the backup the commit sets aside
  /// is not the file the save checked, so it goes back, and nothing is overwritten.
  @Test func aFileTheDeviceReplacesDuringTheUploadIsKept() async throws {
    let device = SessionFixture.makeDevice()
    let old = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = try await session.item(at: SessionFixture.path("/a.txt"), in: storage)
    await device.onUpload { _ in
      await device.removeObject(old)
      await device.addFile(
        "a.txt", parent: SessionFixture.root, data: Data("swapped during the upload".utf8))
    }
    let local = try SessionFixture.localFile(Data("mac edit".utf8))
    defer { try? FileManager.default.removeItem(at: local) }

    await #expect(throws: TransportError.changedOnDevice(try SessionFixture.path("/a.txt"))) {
      _ = try await SafeWriter(session: session).write(
        from: local, to: SessionFixture.path("/a.txt"), in: storage, replacing: true,
        expecting: checked, progress: SessionFixture.noProgress)
    }
    #expect(await device.children(of: SessionFixture.root) == ["a.txt"])
    let left = await device.objects.values.map { String(bytes: $0.data, encoding: .utf8) }
    #expect(left == ["swapped during the upload"])
  }

  @Test func deletingAFileTheDeviceDroppedIsNotFound() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("a".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(id)

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      try await session.delete(SessionFixture.path("/a.txt"), in: storage)
    }
  }

  @Test func downloadingAFileTheDeviceReplacedGetsTheNewOne() async throws {
    let (_, session) = try await listedThenReplaced()
    let target = TestScratch.root.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }

    try await session.download(
      SessionFixture.path("/a.txt"), in: storage, to: target, replacing: true,
      progress: SessionFixture.noProgress)

    #expect(try Data(contentsOf: target) == Data("replaced on the unit".utf8))
  }
}

/// Deleting a folder empties it child by child, at most `RemotePath.maxTreeDepth` levels down,
/// so a device that reports a loop cannot recurse without end.
struct MTPSessionDeleteTreeTests {
  /// `/d1` holding `d2` … `d<levels>`, the last holding `leaf.txt`, `levels` below `/d1`.
  private func deepTree(_ levels: Int) async -> StubMTPDevice {
    let device = SessionFixture.makeDevice()
    var parent = SessionFixture.root
    for level in 1...levels {
      parent = await device.addFolder("d\(level)", parent: parent)
    }
    await device.addFile("leaf.txt", parent: parent, data: Data("x".utf8))
    return device
  }

  @Test func aTreeAsDeepAsFerryWalksIsDeleted() async throws {
    let device = await deepTree(RemotePath.maxTreeDepth)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    try await session.delete(SessionFixture.path("/d1"), in: SessionFixture.storage)

    #expect(await device.objects.isEmpty)
  }

  @Test func aDeeperTreeIsRefusedWithAClearError() async throws {
    let device = await deepTree(RemotePath.maxTreeDepth + 1)
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let top = try SessionFixture.path("/d1")

    await #expect(throws: TransportError.folderTooDeep(top)) {
      try await session.delete(top, in: SessionFixture.storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["d1"])
  }
}

/// A delete given what the caller checked removes exactly that, and nothing if the device has
/// anything else there now.
struct MTPSessionCheckedDeleteTests {
  private let storage = SessionFixture.storage

  private func path(_ string: String) throws -> RemotePath {
    try SessionFixture.path(string)
  }

  @Test func aFileReplacedSinceTheCheckIsNotDeleted() async throws {
    let device = SessionFixture.makeDevice()
    let old = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = try await session.item(at: path("/a.txt"), in: storage)
    await device.removeObject(old)
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("unit edit".utf8))

    await #expect(throws: TransportError.changedOnDevice(try path("/a.txt"))) {
      try await session.delete(path("/a.txt"), in: storage, expecting: [checked])
    }
    #expect(await device.children(of: SessionFixture.root) == ["a.txt"])
  }

  @Test func aFolderThatGainedAnItemIsNotDeletedAtAll() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("F", parent: SessionFixture.root)
    await device.addFile("a.txt", parent: folder, data: Data("a".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = [
      try await session.item(at: path("/F"), in: storage),
      try await session.item(at: path("/F/a.txt"), in: storage),
    ]
    await device.addFile("b.txt", parent: folder, data: Data("new on the unit".utf8))

    await #expect(throws: TransportError.directoryNotEmpty(try path("/F"))) {
      try await session.delete(path("/F"), in: storage, expecting: checked)
    }
    #expect(await device.children(of: folder) == ["a.txt", "b.txt"])
  }

  @Test func theCheckedTreeGoesWithItsHiddenPartials() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("F", parent: SessionFixture.root)
    await device.addFile("a.txt", parent: folder, data: Data("a".utf8))
    await device.addFile(SafeWriter.partialPrefix + "x", parent: folder, data: Data("p".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = [
      try await session.item(at: path("/F"), in: storage),
      try await session.item(at: path("/F/a.txt"), in: storage),
    ]

    try await session.delete(path("/F"), in: storage, expecting: checked)

    #expect(await device.objects.isEmpty)
  }

  /// An item whose name Ferry cannot use was never shown: a checked delete keeps its folder; an
  /// unchecked one takes it with the folder.
  @Test func aFolderHoldingAnUnusableNameIsKeptByACheckedDelete() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("F", parent: SessionFixture.root)
    await device.addFile("bad/name", parent: folder, data: Data("x".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = [try await session.item(at: path("/F"), in: storage)]

    await #expect(throws: TransportError.directoryNotEmpty(try path("/F"))) {
      try await session.delete(path("/F"), in: storage, expecting: checked)
    }
    #expect(await device.children(of: folder) == ["bad/name"])

    try await session.delete(path("/F"), in: storage)
    #expect(await device.objects.isEmpty)
  }

  /// A hidden folder whose name Ferry cannot use is refused like any unusable name: what it holds
  /// would otherwise be checked against its parent's items, and an `a.txt` inside it would pass
  /// as the `a.txt` Finder saw beside it.
  @Test func aHiddenFolderWithAnUnusableNameIsRefusedByACheckedDelete() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("F", parent: SessionFixture.root)
    await device.addFile("a.txt", parent: folder, data: Data("a".utf8))
    let hidden = await device.addFolder(SafeWriter.partialPrefix + "x/y", parent: folder)
    await device.addFile("a.txt", parent: hidden, data: Data("a".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let checked = [
      try await session.item(at: path("/F"), in: storage),
      try await session.item(at: path("/F/a.txt"), in: storage),
    ]

    await #expect(throws: TransportError.directoryNotEmpty(try path("/F"))) {
      try await session.delete(path("/F"), in: storage, expecting: checked)
    }
    #expect(await device.objects.count == 4)
  }
}
