import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// An operation on one item resolves it from the cached listing of its folder and confirms it
/// with one call for that object, so deleting many files from a large folder lists the folder
/// once, not once per file. The device is listed again only when the cache cannot answer.
struct MTPSessionCacheTests {
  private let storage = SessionFixture.storage

  @Test func deletingManyFilesFromALargeFolderListsItOnce() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("Big", parent: SessionFixture.root)
    for index in 0..<1_000 {
      await device.addFile("f\(index).txt", parent: folder, data: Data("x".utf8))
    }
    let session = MTPSession(device: device)
    _ = try await session.list(SessionFixture.path("/Big"), in: storage)
    let listed = await device.listCount

    for index in 0..<100 {
      let file = try SessionFixture.path("/Big/f\(index).txt")
      // As the agent deletes: reads the item, then deletes it.
      _ = try await session.item(at: file, in: storage)
      try await session.delete(file, in: storage)
    }

    let relisted = await device.listCount - listed
    #expect(relisted == 0, "listed the folder \(relisted) more times")
    #expect(await device.children(of: folder).count == 900)
  }

  @Test func anObjectMovedToAnotherFolderIsNotActedOnFromTheCache() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("a".utf8))
    let other = await device.addFolder("Other", parent: SessionFixture.root)
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.moveObject(id, to: other)

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      try await session.delete(SessionFixture.path("/a.txt"), in: storage)
    }
    #expect(await device.children(of: other) == ["a.txt"])
  }

  @Test func anObjectRenamedOnTheDeviceIsNotActedOnFromTheCache() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("a".utf8))
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.renameObject(id, to: "b.txt")

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      _ = try await session.item(at: SessionFixture.path("/a.txt"), in: storage)
    }
  }
}

/// libmtp keeps the object info it loaded for an ID and never reads it again, so confirming a
/// cached object by its ID cannot see that the device dropped or replaced it. The operation on it
/// then fails, and the session lists the folder again to tell what happened.
struct MTPSessionStaleObjectInfoTests {
  private let storage = SessionFixture.storage

  private func listedThenReplaced() async throws -> (StubMTPDevice, MTPSession) {
    let device = SessionFixture.makeDevice()
    await device.cacheObjectInfo()
    let old = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(old)
    await device.addFile(
      "a.txt", parent: SessionFixture.root, data: Data("replaced on the unit".utf8))
    return (device, session)
  }

  @Test func deletingAFileTheDeviceDroppedIsNotFound() async throws {
    let device = SessionFixture.makeDevice()
    await device.cacheObjectInfo()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("a".utf8))
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(id)

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      try await session.delete(SessionFixture.path("/a.txt"), in: storage)
    }
  }

  /// The object now at the path is not the one the delete was for: it stays.
  @Test func deletingAFileTheDeviceReplacedKeepsTheNewOne() async throws {
    let (device, session) = try await listedThenReplaced()

    await #expect(throws: TransportError.notFound(try SessionFixture.path("/a.txt"))) {
      try await session.delete(SessionFixture.path("/a.txt"), in: storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["a.txt"])
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
    let session = MTPSession(device: device)

    try await session.delete(SessionFixture.path("/d1"), in: SessionFixture.storage)

    #expect(await device.objects.isEmpty)
  }

  @Test func aDeeperTreeIsRefusedWithAClearError() async throws {
    let device = await deepTree(RemotePath.maxTreeDepth + 1)
    let session = MTPSession(device: device)
    let top = try SessionFixture.path("/d1")

    await #expect(throws: TransportError.folderTooDeep(top)) {
      try await session.delete(top, in: SessionFixture.storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["d1"])
  }
}
