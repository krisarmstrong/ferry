import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// A device may store an object under another name than it was sent; the session must say so.
struct MTPSessionNameChangeTests {
  @Test func uploadStoredUnderAnotherNameIsRemovedAndReported() async throws {
    let device = SessionFixture.makeDevice()
    await device.storeName("Report.txt", as: "REPORT.TXT")
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let file = try SessionFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    await #expect(
      throws: TransportError.nameChangedByDevice(requested: "Report.txt", actual: "REPORT.TXT")
    ) {
      _ = try await session.upload(
        from: file, to: SessionFixture.path("/Report.txt"), in: SessionFixture.storage,
        progress: SessionFixture.noProgress)
    }
    #expect(await device.children(of: SessionFixture.root) == [])
    #expect(try await session.list(.root, in: SessionFixture.storage).isEmpty)
  }

  @Test func renameStoredUnderAnotherNameKeepsTheObject() async throws {
    let device = SessionFixture.makeDevice()
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("x".utf8))
    await device.storeName("b.txt", as: "b (1).txt")
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(
      throws: TransportError.nameChangedByDevice(requested: "b.txt", actual: "b (1).txt")
    ) {
      _ = try await session.rename(
        SessionFixture.path("/a.txt"), to: "b.txt", in: SessionFixture.storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["b (1).txt"])
    let item = try await session.item(
      at: SessionFixture.path("/b (1).txt"), in: SessionFixture.storage)
    #expect(item.size == 1)
  }

  @Test func makeFolderStoredUnderAnotherNameIsReported() async throws {
    let device = SessionFixture.makeDevice()
    await device.storeName("Caf\u{00E9}", as: "Caf_")
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(
      throws: TransportError.nameChangedByDevice(requested: "Caf\u{00E9}", actual: "Caf_")
    ) {
      _ = try await session.makeFolder(
        SessionFixture.path("/Caf\u{00E9}"), in: SessionFixture.storage)
    }
    #expect(await device.children(of: SessionFixture.root) == ["Caf_"])
  }
}
