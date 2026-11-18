import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// A storage that goes away while the session is open (an SD card ejected, internal storage
/// unmounted) is a missing storage, never a missing item: FileProvider deletes its local copies
/// of an item reported missing.
struct ADBSessionStorageLossTests {
  static let volume = StorageID(device: ADBFixture.deviceID, key: "volume:1234-ABCD")

  @Test func everyCallOnARemovedCardIsStorageNotFound() async throws {
    let device = FakeAndroid(volumes: ["1234-ABCD"])
    device.state.withLock {
      $0.nodes[FakeAndroid.bytes("/storage/1234-ABCD/a.txt")] = .file(Data("a".utf8), mtime: 1)
    }
    let folder = try ADBFixture.downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try RemotePath("/a.txt")
    let gone = TransportError.storageNotFound(Self.volume.key)
    try await ADBFixture.withSession(device) { session in
      let listed = try await session.list(.root, in: Self.volume)
      #expect(listed.count == 1)
      device.removeMount("/storage/1234-ABCD")
      await #expect(throws: gone) { _ = try await session.list(.root, in: Self.volume) }
      await #expect(throws: gone) { _ = try await session.item(at: .root, in: Self.volume) }
      await #expect(throws: gone) { _ = try await session.item(at: file, in: Self.volume) }
      await #expect(throws: gone) { try await session.delete(file, in: Self.volume) }
      await #expect(throws: gone) {
        try await session.download(
          file, in: Self.volume, to: folder.appending(path: "a.txt"), replacing: false,
          progress: ADBFixture.noProgress)
      }
      let storages = try await session.storages()
      #expect(storages.map(\.id.key) == ["internal"])
    }
  }

  /// The root's own `item` is checked against the device, not made up.
  @Test func theRootOfAStorageThatIsGoneIsNotAFolder() async throws {
    let device = FakeAndroid()
    try await ADBFixture.withSession(device) { session in
      _ = try await session.storages()
      device.removeMount(FakeAndroid.internalRoot)
      await #expect(throws: TransportError.storageNotFound("internal")) {
        _ = try await session.item(at: .root, in: ADBFixture.storage)
      }
    }
  }

  /// A name the clash check cannot see as taken (vfat ignores trailing dots on lookup) still
  /// never reaches SEND, which would delete what the device resolves it to.
  @Test func anUploadToANameTheDeviceResolvesElsewhereIsRefused() async throws {
    let device = FakeAndroid(volumes: ["1234-ABCD"], vfat: true)
    device.state.withLock {
      $0.nodes[FakeAndroid.bytes("/storage/1234-ABCD/a.txt")] = .file(Data("keep".utf8), mtime: 1)
    }
    let file = try ADBFixture.localFile(Data("new".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let alias = try RemotePath("/a.txt.")
    await #expect(throws: TransportError.alreadyExists(alias)) {
      try await ADBFixture.withSession(device) { session in
        _ = try await session.upload(
          from: file, to: alias, in: Self.volume, progress: ADBFixture.noProgress)
      }
    }
    #expect(!device.syncRequests.contains { $0.id == "SEND" })
    #expect(
      device.state.withLock { $0.nodes[FakeAndroid.bytes("/storage/1234-ABCD/a.txt")] }
        == .file(Data("keep".utf8), mtime: 1))
  }
}
