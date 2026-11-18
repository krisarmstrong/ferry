import DeviceKitTestSupport
import Foundation
import Testing

@testable import DeviceKit

struct SafeWriterTests {
  static let deviceID = DeviceID(serial: "FAKE1")
  static let storageID = StorageID(device: deviceID, key: "Internal|vol0")
  var deviceID: DeviceID { Self.deviceID }
  var storageID: StorageID { Self.storageID }

  func makeDevice(free: UInt64 = 5_000_000_000, isFATLike: Bool = false) -> FakeDevice {
    FakeDevice(
      info: DeviceInfo(id: deviceID, manufacturer: "Fake", model: "Phone"),
      storages: [
        StorageInfo(
          id: StorageID(device: deviceID, key: "Internal|vol0"), description: "Internal",
          capacity: 10_000_000_000, free: free, isFATLike: isFATLike)
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

  /// A partial registered by anyone on the session, not only by this writer, survives listing:
  /// the session's own move fallback registers its partials there too.
  @Test func listingDoesNotDeleteInFlightPartial() async throws {
    let device = makeDevice()
    let partial = try RemotePath("/.ferry-partial-MOVE")
    try await device.seed(partial, in: storageID, contents: Data([1]))
    await device.partials.registerInFlight(partial, in: storageID)

    #expect(try await SafeWriter(session: device).visibleList(.root, in: storageID).isEmpty)
    #expect(try await SafeWriter(session: device).visibleList(.root, in: storageID).isEmpty)
    #expect(await device.allPaths(in: storageID) == [partial])

    await device.partials.unregisterInFlight(partial, in: storageID)
    #expect(try await SafeWriter(session: device).visibleList(.root, in: storageID).isEmpty)
    #expect(await device.allPaths(in: storageID).isEmpty)
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

  /// Only a storage known to be FAT has a 4 GB file limit to blame. Elsewhere the device's own
  /// error is the one shown.
  @Test(arguments: [true, false])
  func oversizeRejectionMapsToTooLargeOnlyOnFAT(isFATLike: Bool) async throws {
    let device = makeDevice(isFATLike: isFATLike)
    let writer = SafeWriter(session: device)
    let size: UInt64 = 4_294_967_296
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: size)
    try handle.close()

    await device.failUpload(afterBytes: 0, with: .io("rejected"))
    let expected: TransportError =
      isFATLike ? .fileTooLargeForStorage(size: size) : .io("rejected")
    await #expect(throws: expected) {
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

  /// An unknown storage must not read as "nothing there", which would skip the space check.
  @Test func unknownStorageIsRejectedBeforeUpload() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let unknown = StorageID(device: deviceID, key: "SD|vol9")
    try await withTempFile(Data([1, 2])) { file in
      await #expect(throws: TransportError.storageNotFound(unknown.key)) {
        _ = try await writer.write(
          from: file, to: RemotePath("/a.txt"), in: unknown, replacing: false,
          progress: { _, _ in true })
      }
    }
    #expect(await device.allPaths(in: storageID).isEmpty)
  }

  @Test func replacingSwapsInTheNewFileThenDropsTheOld() async throws {
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

  /// libmtp sends exactly the size it is told, so a link's own size would truncate the upload.
  @Test func symlinkUploadsTheTargetsFullSize() async throws {
    let device = makeDevice()
    let writer = SafeWriter(session: device)
    let path = try RemotePath("/a.txt")
    let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: link) }
    let payload = Data(repeating: 7, count: 300)
    try await withTempFile(payload) { file in
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
      let item = try await writer.write(from: link, to: path, replacing: false)
      #expect(item.size == 300)
    }
    #expect(await device.contents(of: path, in: storageID) == payload)
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
    await device.failList(with: .notFound(.root))
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
    await device.failList(with: .deviceBusy)
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
  func write(from file: URL, to path: RemotePath, replacing: Bool)
    async throws(TransportError) -> RemoteItem
  {
    try await write(
      from: file, to: path, in: SafeWriterTests.storageID, replacing: replacing,
      progress: { _, _ in true })
  }
}
