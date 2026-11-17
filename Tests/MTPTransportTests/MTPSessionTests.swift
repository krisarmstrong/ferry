import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

struct MTPSessionTests {
  // MARK: Storages

  @Test func storagesReturnsDeviceStorages() async throws {
    let session = MTPSession(device: SessionFixture.makeDevice())
    #expect(try await session.storages().map(\.id) == [SessionFixture.storage])
  }

  @Test func storageIsFoundByKeyWithoutCallingStoragesFirst() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFolder("DCIM", parent: SessionFixture.root)
    let session = MTPSession(device: device)
    let items = try await session.list(.root, in: SessionFixture.storage)
    #expect(items.map(\.path) == [try SessionFixture.path("/DCIM")])
  }

  @Test func storageIsNotFoundByRawID() async throws {
    let session = MTPSession(device: SessionFixture.makeDevice())
    let byRawID = StorageID(device: SessionFixture.deviceID, key: String(SessionFixture.rawStorage))
    await #expect(throws: TransportError.storageNotFound(byRawID.key)) {
      _ = try await session.list(.root, in: byRawID)
    }
  }

  @Test func storageOfAnotherDeviceIsNotFound() async throws {
    let session = MTPSession(device: SessionFixture.makeDevice())
    let other = StorageID(device: DeviceID(serial: "OTHER"), key: SessionFixture.storage.key)
    await #expect(throws: TransportError.storageNotFound(other.key)) {
      _ = try await session.list(.root, in: other)
    }
  }

  // MARK: Reading

  @Test func listMapsEntriesAndSkipsUnusableNames() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFolder("DCIM", parent: SessionFixture.root)
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("abc".utf8))
    await device.addFile("", parent: SessionFixture.root, data: Data())
    await device.addFile("..", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device)

    let items = try await session.list(.root, in: SessionFixture.storage)
    let folder = RemoteItem(
      path: try SessionFixture.path("/DCIM"), kind: .folder, size: 0,
      modified: StubMTPDevice.epoch)
    let file = RemoteItem(
      path: try SessionFixture.path("/a.txt"), kind: .file, size: 3, modified: StubMTPDevice.epoch)
    #expect(items == [folder, file])
  }

  /// MTP has no change events, so a listing is the moment to re-read the device.
  @Test func listSeesChangesMadeOnThePhone() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device)
    #expect(try await session.list(.root, in: SessionFixture.storage).isEmpty)

    await device.addFile("new.jpg", parent: SessionFixture.root, data: Data())
    let items = try await session.list(.root, in: SessionFixture.storage)
    #expect(items.map(\.path) == [try SessionFixture.path("/new.jpg")])
  }

  @Test func itemReportsKindSizeAndModified() async throws {
    let device = SessionFixture.makeDevice()
    let dcim = await device.addFolder("DCIM", parent: SessionFixture.root)
    await device.addFile("a.jpg", parent: dcim, data: Data(count: 1234))
    let session = MTPSession(device: device)

    let file = try await session.item(
      at: SessionFixture.path("/DCIM/a.jpg"), in: SessionFixture.storage)
    #expect(file.kind == .file)
    #expect(file.size == 1234)
    #expect(file.modified == StubMTPDevice.epoch)
    #expect(file.path == (try SessionFixture.path("/DCIM/a.jpg")))

    let folder = try await session.item(
      at: SessionFixture.path("/DCIM"), in: SessionFixture.storage)
    #expect(folder.kind == .folder)
    #expect(folder.size == 0)

    #expect(try await session.item(at: .root, in: SessionFixture.storage).kind == .folder)
  }

  @Test func downloadWritesContents() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("hello".utf8))
    let session = MTPSession(device: device)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }

    try await session.download(
      SessionFixture.path("/a.txt"), in: SessionFixture.storage, to: target,
      progress: SessionFixture.noProgress)
    #expect(try Data(contentsOf: target) == Data("hello".utf8))
  }

  @Test func missingPathsThrowNotFound() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFolder("DCIM", parent: SessionFixture.root)
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device)
    let missing = try SessionFixture.path("/DCIM/missing.jpg")
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    await #expect(throws: TransportError.notFound(missing)) {
      _ = try await session.item(at: missing, in: SessionFixture.storage)
    }
    await #expect(throws: TransportError.notFound(missing)) {
      _ = try await session.list(missing, in: SessionFixture.storage)
    }
    await #expect(throws: TransportError.notFound(missing)) {
      try await session.download(
        missing, in: SessionFixture.storage, to: target, progress: SessionFixture.noProgress)
    }
    await #expect(throws: TransportError.notFound(missing)) {
      _ = try await session.rename(missing, to: "b.jpg", in: SessionFixture.storage)
    }
    await #expect(throws: TransportError.notFound(missing)) {
      _ = try await session.move(missing, toFolder: .root, in: SessionFixture.storage)
    }
    await #expect(throws: TransportError.notFound(missing)) {
      try await session.delete(missing, in: SessionFixture.storage)
    }
    let missingFolder = try SessionFixture.path("/Nope")
    await #expect(throws: TransportError.notFound(missingFolder)) {
      _ = try await session.upload(
        from: file, to: missingFolder.appending("x"), in: SessionFixture.storage,
        progress: SessionFixture.noProgress)
    }
    let fileAsFolder = try SessionFixture.path("/a.txt")
    await #expect(throws: TransportError.notFound(fileAsFolder)) {
      _ = try await session.makeFolder(fileAsFolder.appending("x"), in: SessionFixture.storage)
    }
    await #expect(throws: TransportError.notFound(fileAsFolder)) {
      _ = try await session.move(
        SessionFixture.path("/DCIM"), toFolder: fileAsFolder, in: SessionFixture.storage)
    }
    #expect(await device.calls.isEmpty)
  }

  // MARK: Lifecycle

  @Test func closeClosesDevice() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device)
    await session.close()
    #expect(await device.closed)
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await session.list(.root, in: SessionFixture.storage)
    }
  }
}
