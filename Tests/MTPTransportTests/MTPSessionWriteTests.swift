import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

struct MTPSessionWriteTests {
  // MARK: Writing

  @Test func uploadToExistingNameThrowsWithoutUploading() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let file = try SessionFixture.localFile(Data("new".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    let path = try SessionFixture.path("/a.txt")
    await #expect(throws: TransportError.alreadyExists(path)) {
      _ = try await session.upload(
        from: file, to: path, in: SessionFixture.storage, progress: SessionFixture.noProgress)
    }
    #expect(await device.uploadCount == 0)
  }

  @Test func uploadReturnsDeviceReportedSize() async throws {
    let device = SessionFixture.makeDevice()
    await device.limitUploads(to: 2)
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let file = try SessionFixture.localFile(Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    let item = try await session.upload(
      from: file, to: SessionFixture.path("/a.txt"), in: SessionFixture.storage,
      progress: SessionFixture.noProgress)
    #expect(item.size == 2)
    #expect(item.kind == .file)
    #expect(item.path == (try SessionFixture.path("/a.txt")))
  }

  @Test func makeFolderAndRenameRejectExistingNames() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFolder("A", parent: SessionFixture.root)
    await device.addFile("b.txt", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/A"))) {
      _ = try await session.makeFolder(SessionFixture.path("/A"), in: SessionFixture.storage)
    }
    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/A"))) {
      _ = try await session.rename(
        SessionFixture.path("/b.txt"), to: "A", in: SessionFixture.storage)
    }
    #expect(await device.calls.isEmpty)
  }

  @Test func namesSentToDeviceAreNFC() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let nfd = "Cafe\u{0301}"
    let nfc = "Caf\u{00E9}"
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    _ = try await session.makeFolder(RemotePath.root.appending(nfd), in: SessionFixture.storage)
    _ = try await session.upload(
      from: file, to: RemotePath.root.appending(nfd).appending(nfd + ".txt"),
      in: SessionFixture.storage,
      progress: SessionFixture.noProgress)
    let renamed = try await session.rename(
      RemotePath.root.appending(nfd), to: nfd + "2", in: SessionFixture.storage)

    #expect(await device.sentNames == [nfc, nfc + ".txt", nfc + "2"])
    #expect(renamed.path.name == nfc + "2")
  }

  @Test func listSeesEveryMutation() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    func names(_ folder: String = "/") async throws -> [String] {
      try await session.list(SessionFixture.path(folder), in: SessionFixture.storage).compactMap(
        \.path.name)
    }

    #expect(try await names() == [])
    _ = try await session.makeFolder(SessionFixture.path("/A"), in: SessionFixture.storage)
    #expect(try await names() == ["A"])
    _ = try await session.makeFolder(SessionFixture.path("/B"), in: SessionFixture.storage)
    #expect(try await names("/A") == [])
    _ = try await session.upload(
      from: file, to: SessionFixture.path("/A/f.txt"), in: SessionFixture.storage,
      progress: SessionFixture.noProgress)
    #expect(try await names("/A") == ["f.txt"])
    _ = try await session.rename(
      SessionFixture.path("/A/f.txt"), to: "g.txt", in: SessionFixture.storage)
    #expect(try await names("/A") == ["g.txt"])
    _ = try await session.move(
      SessionFixture.path("/A/g.txt"), toFolder: SessionFixture.path("/B"),
      in: SessionFixture.storage)
    #expect(try await names("/A") == [])
    #expect(try await names("/B") == ["g.txt"])
    try await session.delete(SessionFixture.path("/B"), in: SessionFixture.storage)
    #expect(try await names() == ["A"])
  }

  @Test func renamedFolderChildrenResolveAtNewPath() async throws {
    let device = SessionFixture.makeDevice()
    let folder = await device.addFolder("A", parent: SessionFixture.root)
    await device.addFile("f.txt", parent: folder, data: Data("x".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)

    _ = try await session.item(at: SessionFixture.path("/A/f.txt"), in: SessionFixture.storage)
    _ = try await session.rename(SessionFixture.path("/A"), to: "B", in: SessionFixture.storage)
    #expect(
      try await session.item(at: SessionFixture.path("/B/f.txt"), in: SessionFixture.storage).size
        == 1)
    await #expect(throws: TransportError.notFound(try SessionFixture.path("/A/f.txt"))) {
      _ = try await session.item(at: SessionFixture.path("/A/f.txt"), in: SessionFixture.storage)
    }
  }

  /// SafeWriter deletes the target of a failed upload; the device may have kept the object,
  /// so the session must not answer that delete from a stale listing.
  @Test func failedUploadLeavesTargetDeletable() async throws {
    let device = SessionFixture.makeDevice()
    await device.failNextUpload(with: .deviceBusy)
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let path = try SessionFixture.path("/a.txt")
    _ = try await session.list(.root, in: SessionFixture.storage)

    await #expect(throws: TransportError.deviceBusy) {
      _ = try await session.upload(
        from: file, to: path, in: SessionFixture.storage, progress: SessionFixture.noProgress)
    }
    try await session.delete(path, in: SessionFixture.storage)
    #expect(await device.children(of: SessionFixture.root) == [])
  }

  // MARK: Delete

  @Test func deleteFolderRemovesChildrenDepthFirst() async throws {
    let device = SessionFixture.makeDevice()
    let folderA = await device.addFolder("A", parent: SessionFixture.root)
    let folderB = await device.addFolder("B", parent: folderA)
    let fileC = await device.addFile("c.txt", parent: folderB, data: Data())
    let fileD = await device.addFile("d.txt", parent: folderA, data: Data())
    await device.addFile("keep.txt", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device, scratch: TestScratch.root)

    try await session.delete(SessionFixture.path("/A"), in: SessionFixture.storage)
    #expect(
      await device.calls == [.delete(fileC), .delete(folderB), .delete(fileD), .delete(folderA)])
    #expect(await device.children(of: SessionFixture.root) == ["keep.txt"])
  }

  // MARK: Move

  @Test func moveWithCapabilityUsesDeviceMove() async throws {
    let device = SessionFixture.makeDevice(capabilities: [.move])
    let file = await device.addFile("a.txt", parent: SessionFixture.root, data: Data("x".utf8))
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    let item = try await session.move(
      SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"), in: SessionFixture.storage
    )
    #expect(item.path == (try SessionFixture.path("/B/a.txt")))
    #expect(await device.calls == [.move(file, parent: dest)])
  }

  @Test func moveToExistingNameThrows() async throws {
    let device = SessionFixture.makeDevice(capabilities: [.move])
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data())
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    await device.addFile("a.txt", parent: dest, data: Data())
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/B/a.txt"))) {
      _ = try await session.move(
        SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"),
        in: SessionFixture.storage)
    }
    #expect(await device.calls.isEmpty)
  }

  @Test func moveWithoutCapabilityCopiesThroughPartialThenDeletes() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    let source = await device.addFile(
      "a.txt", parent: SessionFixture.root, data: Data("payload".utf8))
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    let item = try await session.move(
      SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"), in: SessionFixture.storage
    )
    #expect(item.path == (try SessionFixture.path("/B/a.txt")))
    #expect(item.size == 7)

    let calls = await device.calls
    #expect(calls.count == 3)
    guard calls.count == 3, case .upload(let partial, let parent) = calls[0],
      case .rename(let copy, let finalName) = calls[1]
    else {
      Issue.record("unexpected calls: \(calls)")
      return
    }
    #expect(SafeWriter.isPartial(partial))
    #expect(parent == dest)
    #expect(finalName == "a.txt")
    #expect(calls[2] == .delete(source))
    #expect(await device.objects[copy]?.data == Data("payload".utf8))
    #expect(await device.children(of: SessionFixture.root) == ["B"])
  }

  @Test func moveFallbackKeepsSourceWhenCopyComesUpShort() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("payload".utf8))
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    await device.limitUploads(to: 3)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.sizeMismatch(expected: 7, actual: 3)) {
      _ = try await session.move(
        SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"),
        in: SessionFixture.storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["B", "a.txt"])
    #expect(await device.children(of: dest) == [])
  }

  @Test func moveFallbackKeepsSourceWhenUploadFails() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("payload".utf8))
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    await device.failNextUpload(with: .deviceBusy)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.deviceBusy) {
      _ = try await session.move(
        SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"),
        in: SessionFixture.storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["B", "a.txt"])
    #expect(await device.children(of: dest) == [])
  }

  @Test func moveFolderWithoutCapabilityIsUnsupported() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    await device.addFolder("A", parent: SessionFixture.root)
    await device.addFolder("B", parent: SessionFixture.root)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.unsupported("move")) {
      _ = try await session.move(
        SessionFixture.path("/A"), toFolder: SessionFixture.path("/B"), in: SessionFixture.storage)
    }
    #expect(await device.calls.isEmpty)
  }
}
