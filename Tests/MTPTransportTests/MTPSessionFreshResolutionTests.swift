import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

/// A listing caches the folder, and the device can change behind it (an app on the phone, the
/// user at the unit). Operations that act on one item resolve it fresh, so they never act on a
/// stale size or on an object ID the device has since reused or dropped.
struct MTPSessionFreshResolutionTests {
  private let storage = SessionFixture.storage

  @Test func downloadAfterTheFileGrewOnTheDeviceGetsTheWholeFile() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    let grown = Data("hello, world, grown on the phone".utf8)
    await device.replaceData(of: id, with: grown)

    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }
    try await session.download(
      SessionFixture.path("/a.txt"), in: storage, to: target, replacing: true,
      progress: SessionFixture.noProgress)

    #expect(try Data(contentsOf: target) == grown)
  }

  @Test func itemAfterTheFileGrewOnTheDeviceReportsTheNewSize() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.replaceData(of: id, with: Data("grown!".utf8))

    let item = try await session.item(at: SessionFixture.path("/a.txt"), in: storage)

    #expect(item.size == 6)
  }

  @Test func deleteAfterTheDeviceRecreatedTheFileDeletesTheNewObject() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(id)
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("new".utf8))

    try await session.delete(SessionFixture.path("/a.txt"), in: storage)

    #expect(await device.children(of: SessionFixture.root).isEmpty)
  }

  @Test func moveAfterTheDeviceRecreatedTheFileMovesTheNewObject() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    let folder = await device.addFolder("Docs", parent: SessionFixture.root)
    let session = MTPSession(device: device)
    _ = try await session.list(.root, in: storage)
    await device.removeObject(id)
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("new".utf8))

    _ = try await session.move(
      SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/Docs"), in: storage)

    #expect(await device.children(of: folder) == ["a.txt"])
  }

  /// A device whose metadata is stale (an app rewrote the file) lists fewer bytes than it
  /// sends. libmtp reports the transfer complete, so the file is whole: it is kept, at the
  /// size received.
  @Test func aDownloadLongerThanListedIsKeptAtItsRealSize() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("global.o", parent: SessionFixture.root, data: Data(count: 40))
    await device.reportSize(32, for: id)
    let session = MTPSession(device: device)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }

    let result = try await session.download(
      SessionFixture.path("/global.o"), in: storage, to: target, replacing: true,
      progress: SessionFixture.noProgress)

    #expect(try Data(contentsOf: target).count == 40)
    #expect(result.listed.size == 32)
    #expect(result.received == 40)
  }

  @Test func aShortDownloadIsTriedOnceMore() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    await device.cutShortNextDownloads(1)
    let session = MTPSession(device: device)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }

    let result = try await session.download(
      SessionFixture.path("/a.txt"), in: storage, to: target, replacing: true,
      progress: SessionFixture.noProgress)

    #expect(try Data(contentsOf: target) == Data("hello".utf8))
    #expect(result.received == 5)
    #expect(await device.downloadCount == 2)
  }

  @Test func aShortDownloadSaysTheDeviceSentLessThanItListed() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    await device.limitDownloads(to: 2)
    let session = MTPSession(device: device)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    await #expect(throws: TransportError.downloadSizeMismatch(listed: 5, received: 2)) {
      try await session.download(
        SessionFixture.path("/a.txt"), in: storage, to: target, replacing: true,
        progress: SessionFixture.noProgress)
    }
    // Tried twice, then reported truncated.
    #expect(await device.downloadCount == 2)
  }
}
