import DeviceKitTestSupport
import Foundation
import Testing

@testable import DeviceKit

struct SafeWriterTests {
  static let deviceID = DeviceID(serial: "FAKE1")
  static let storageID = StorageID(device: deviceID, key: "Internal|vol0")
  var deviceID: DeviceID { Self.deviceID }
  var storageID: StorageID { Self.storageID }

  func makeDevice(free: UInt64 = 5_000_000_000) -> FakeDevice {
    FakeDevice(
      info: DeviceInfo(id: deviceID, manufacturer: "Fake", model: "Phone"),
      storages: [
        StorageInfo(
          id: StorageID(device: deviceID, key: "Internal|vol0"), description: "Internal",
          capacity: 10_000_000_000, free: free)
      ])
  }

  /// Runs `body` with a temp file holding `data`, removing the file afterwards.
  @discardableResult
  func withTempFile<T>(_ data: Data, _ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
  }

  func partials(_ device: FakeDevice) async -> [RemotePath] {
    await device.allPaths(in: storageID).filter { SafeWriter.isPartial($0.name ?? "") }
  }

  @Test func writesViaTempThenRenames() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await withTempFile(Data([1, 2, 3, 4])) { file in
      let item = try await writer.write(from: file, to: path, replacing: false)
      #expect(item.path == path)
    }
    #expect(await device.contents(of: path, in: storageID) == Data([1, 2, 3, 4]))
    #expect(await partials(device).isEmpty)
  }

  @Test func disconnectMidUploadLeavesNoFinalName() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    await device.failUpload(afterBytes: 2, with: .deviceDisconnected)
    try await withTempFile(Data([1, 2, 3, 4])) { file in
      await #expect(throws: TransportError.deviceDisconnected) {
        _ = try await writer.write(from: file, to: path, replacing: false)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == nil)
    #expect(await partials(device).isEmpty)
  }

  @Test func listingHidesAndDeletesPartials() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    try await device.seed(RemotePath("/a.txt"), in: storageID, contents: Data([1]))
    try await device.seed(RemotePath("/.ferry-partial-X"), in: storageID, contents: Data([1]))

    let visible = try await writer.visibleList(.root, in: storageID)
    #expect(visible.map(\.path) == [try RemotePath("/a.txt")])
    #expect(await device.allPaths(in: storageID) == [try RemotePath("/a.txt")])
  }

  @Test func listingDoesNotDeleteInFlightPartial() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let partial = try RemotePath("/.ferry-partial-LIVE")
    try await device.seed(partial, in: storageID, contents: Data([1]))
    await writer.registry.register(storageID, partial)

    let visible = try await writer.visibleList(.root, in: storageID)
    #expect(visible.isEmpty)
    #expect(await device.allPaths(in: storageID) == [partial])
  }

  @Test func shortWriteThrowsSizeMismatchAndCleansUp() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    await device.truncateUploads(to: 1)
    try await withTempFile(Data([1, 2, 3, 4])) { file in
      await #expect(throws: TransportError.sizeMismatch(expected: 4, actual: 1)) {
        _ = try await writer.write(from: file, to: RemotePath("/a.txt"), replacing: false)
      }
    }
    #expect(await device.allPaths(in: storageID).isEmpty)
  }

  @Test func oversizeRejectionMapsToTooLarge() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let size: UInt64 = 4_294_967_296
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: size)
    try handle.close()

    await device.failUpload(afterBytes: 0, with: .io("rejected"))
    await #expect(throws: TransportError.fileTooLargeForStorage(size: size)) {
      _ = try await writer.write(from: url, to: RemotePath("/big.bin"), replacing: false)
    }
    #expect(await device.allPaths(in: storageID).isEmpty)
  }

  @Test func insufficientSpaceRejectedBeforeUpload() async throws {
    let device = makeDevice(free: 2)
    let writer = SafeWriter(session: device)
    try await withTempFile(Data([1, 2, 3, 4])) { file in
      await #expect(throws: TransportError.insufficientSpace(needed: 4, free: 2)) {
        _ = try await writer.write(from: file, to: RemotePath("/a.txt"), replacing: false)
      }
    }
    #expect(await device.allPaths(in: storageID).isEmpty)
  }

  @Test func replacingDeletesOldThenRenames() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      _ = try await writer.write(from: file, to: path, replacing: true)
    }
    #expect(await device.contents(of: path, in: storageID) == Data([1, 2]))
    #expect(await device.allPaths(in: storageID) == [path])
  }

  @Test func notReplacingThrowsAlreadyExists() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.alreadyExists(path)) {
        _ = try await writer.write(from: file, to: path, replacing: false)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Data([9]))
    #expect(await partials(device).isEmpty)
  }

  @Test func renameFailureFallsBackToDirectUpload() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    await device.failRename(with: .unsupported("rename"))
    try await withTempFile(Data([1, 2, 3])) { file in
      _ = try await writer.write(from: file, to: path, replacing: false)
    }
    #expect(await device.contents(of: path, in: storageID) == Data([1, 2, 3]))
    #expect(await partials(device).isEmpty)
  }

  @Test func uploadOverNFDNameReplacesExisting() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    try await device.seed(RemotePath("/caf\u{00E9}.txt"), in: storageID, contents: Data([9]))
    try await withTempFile(Data([1, 2])) { file in
      _ = try await writer.write(
        from: file, to: RemotePath("/caf\u{0065}\u{0301}.txt"), replacing: true)
    }
    let items = try await device.list(.root, in: storageID)
    #expect(items.count == 1)
    #expect(items.first?.size == 2)
  }

  @Test func renameAlreadyExistsKeepsTheOtherFileAndSurfaces() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    // A false "not found" skips the replace delete, so the rename meets an occupied name.
    await device.failItem(with: .notFound(path))
    await device.failRename(with: .alreadyExists(path))
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.alreadyExists(path)) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Data([9]))
    #expect(await device.allPaths(in: storageID) == [path])
  }

  @Test func existenceCheckErrorOtherThanNotFoundPropagates() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([9]))
    await device.failItem(with: .deviceBusy)
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.deviceBusy) {
        _ = try await writer.write(from: file, to: path, replacing: true)
      }
    }
    #expect(await device.contents(of: path, in: storageID) == Data([9]))
    #expect(await partials(device).isEmpty)
  }
}

extension SafeWriter {
  fileprivate func write(from file: URL, to path: RemotePath, replacing: Bool)
    async throws(TransportError) -> RemoteItem
  {
    try await write(
      from: file, to: path, in: SafeWriterTests.storageID, replacing: replacing,
      progress: { _, _ in true })
  }
}
