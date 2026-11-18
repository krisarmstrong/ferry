import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// Android storage (FAT and exFAT cards, emulated internal storage) compares names without
/// case, so a name differing only in case is taken.
struct MTPSessionCaseCollisionTests {
  let storage = SessionFixture.storage

  @Test func uploadOntoCaseVariantThrowsWithTheExistingPath() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("foo.txt", parent: SessionFixture.root, data: Data("old".utf8))
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let file = try SessionFixture.localFile(Data("new".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/foo.txt"))) {
      _ = try await session.upload(
        from: file, to: SessionFixture.path("/Foo.txt"), in: storage,
        progress: SessionFixture.noProgress)
    }
    #expect(await device.calls.isEmpty)
  }

  @Test func makeFolderOntoCaseVariantThrows() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFolder("DCIM", parent: SessionFixture.root)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/DCIM"))) {
      _ = try await session.makeFolder(SessionFixture.path("/dcim"), in: storage)
    }
    #expect(await device.calls.isEmpty)
  }

  @Test func renameOntoCaseVariantThrows() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data())
    await device.addFile("b.txt", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/a.txt"))) {
      _ = try await session.rename(SessionFixture.path("/b.txt"), to: "A.TXT", in: storage)
    }
    #expect(await device.calls.isEmpty)
  }

  @Test func moveOntoCaseVariantThrows() async throws {
    let device = SessionFixture.makeDevice(capabilities: [.move])
    let folder = await device.addFolder("Dest", parent: SessionFixture.root)
    await device.addFile("A.txt", parent: folder, data: Data())
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.alreadyExists(try SessionFixture.path("/Dest/A.txt"))) {
      _ = try await session.move(
        SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/Dest"), in: storage)
    }
    #expect(await device.calls.isEmpty)
  }

  @Test func caseOnlyRenameOfTheSameObjectIsAllowed() async throws {
    let device = SessionFixture.makeDevice()
    let id = await device.addFile("a.txt", parent: SessionFixture.root, data: Data())
    let session = MTPSession(device: device, scratch: TestScratch.root)

    let renamed = try await session.rename(
      SessionFixture.path("/a.txt"), to: "A.txt", in: storage)
    #expect(renamed.path == (try SessionFixture.path("/A.txt")))
    #expect(await device.calls == [.rename(id, name: "A.txt")])
  }
}
