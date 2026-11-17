import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

/// Runs against a real, unlocked Android device through the public transport. These write to
/// the device, so they are off unless `FERRY_DEVICE_TESTS=1`. They share one phone, which only
/// one session can hold at a time, so they run one after another.
extension DeviceTests {
  @Suite struct MTPSessionIntegrationTests {
    static let noProgress: ProgressHandler = { _, _ in true }

    func openFirstSession() async throws -> any DeviceSession {
      let transport = MTPTransport()
      let device = try #require(try await transport.connectedDevices().first, "no MTP device")
      return try await transport.open(device.id)
    }

    /// Runs `body` on a session to the first device and closes it before returning, so the next
    /// test can open the phone again.
    func withSession(_ body: (any DeviceSession) async throws -> Void) async throws {
      let session = try await openFirstSession()
      do {
        try await body(session)
      } catch {
        await session.close()
        throw error
      }
      await session.close()
    }

    /// A fresh folder at the storage root, deleted (with everything in it) after `body`.
    func withTempFolder(
      _ session: any DeviceSession, in storage: StorageID,
      _ body: (RemotePath) async throws -> Void
    ) async throws {
      let folder = try RemotePath.root.appending("ferry-test-\(UUID().uuidString)")
      _ = try await session.makeFolder(folder, in: storage)
      do {
        try await body(folder)
      } catch {
        try? await session.delete(folder, in: storage)
        throw error
      }
      try await session.delete(folder, in: storage)
    }

    @Test func fullRoundTripThroughSafeWriter() async throws {
      let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31) })
      let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try payload.write(to: source)
      defer { try? FileManager.default.removeItem(at: source) }

      try await withSession { session in
        let storage = try #require(try await session.storages().first).id
        let writer = SafeWriter(session: session)
        try await withTempFolder(session, in: storage) { folder in
          let path = try folder.appending("probe.bin")
          let written = try await writer.write(
            from: source, to: path, in: storage, replacing: false, progress: Self.noProgress)
          #expect(written.size == UInt64(payload.count))
          #expect(try await writer.visibleList(folder, in: storage).map(\.path) == [path])

          let item = try await session.item(at: path, in: storage)
          #expect(item.kind == .file)
          #expect(item.size == UInt64(payload.count))

          let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: copy) }
          try await session.download(path, in: storage, to: copy, progress: Self.noProgress)
          #expect(try Data(contentsOf: copy) == payload)

          let renamed = try await session.rename(path, to: "renamed.bin", in: storage)
          #expect(renamed.path == (try folder.appending("renamed.bin")))

          let subfolder = try folder.appending("sub")
          _ = try await session.makeFolder(subfolder, in: storage)
          let moved = try await session.move(renamed.path, toFolder: subfolder, in: storage)
          #expect(moved.path == (try subfolder.appending("renamed.bin")))
          #expect(try await session.list(subfolder, in: storage).map(\.path) == [moved.path])
          #expect(try await writer.visibleList(folder, in: storage).map(\.path) == [subfolder])
        }
      }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FERRY_LARGE_FILE_TESTS"] == "1"))
    func largeFileOver4GB() async throws {
      let size: UInt64 = 4_100_000_000
      let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
      defer { try? FileManager.default.removeItem(at: source) }
      let handle = try FileHandle(forWritingTo: source)
      try handle.truncate(atOffset: size)
      try handle.close()

      try await withSession { session in
        let storage = try #require(try await session.storages().first).id
        try await withTempFolder(session, in: storage) { folder in
          let item = try await SafeWriter(session: session).write(
            from: source, to: folder.appending("large.bin"), in: storage, replacing: false,
            progress: Self.noProgress)
          #expect(item.size == size)
        }
      }
    }

    @Test func storageKeysStableAcrossReopen() async throws {
      var before: [StorageID] = []
      try await withSession { before = try await $0.storages().map(\.id) }
      var after: [StorageID] = []
      try await withSession { after = try await $0.storages().map(\.id) }
      #expect(before == after)
    }
  }
}
