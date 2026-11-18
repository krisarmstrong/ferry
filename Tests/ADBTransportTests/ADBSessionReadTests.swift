import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Storages, listing, item and download on `ADBSession`, against `MTPSession`'s contracts.
struct ADBSessionReadTests {
  let storage = ADBFixture.storage

  func path(_ string: String) throws -> RemotePath { try ADBFixture.path(string) }

  // MARK: Storages

  @Test func internalStorageIsSizedFromDF() async throws {
    let storages = try await ADBFixture.withSession(FakeAndroid()) { try await $0.storages() }
    #expect(
      storages == [
        StorageInfo(
          id: storage, description: "Internal shared storage", capacity: 23_260_324 * 1024,
          free: (23_260_324 - 272_504) * 1024)
      ])
  }

  @Test func eachVolumeIsAStorageAndOtherFoldersAreNot() async throws {
    let device = FakeAndroid(volumes: ["1234-ABCD"])
    device.state.withLock { $0.nodes[FakeAndroid.bytes("/storage/sdcard1")] = .folder(mtime: 1) }
    let storages = try await ADBFixture.withSession(device) { try await $0.storages() }
    #expect(storages.map(\.id.key) == ["internal", "volume:1234-ABCD"])
    #expect(storages.last?.description == "Removable storage")
    #expect(storages.last?.capacity == 62_522_624 * 1024)
  }

  @Test func noStorageIsALockedDevice() async throws {
    let device = FakeAndroid()
    device.removeMount(FakeAndroid.internalRoot)
    await #expect(throws: TransportError.deviceLocked) {
      try await ADBFixture.withSession(device) { _ = try await $0.storages() }
    }
  }

  @Test func aVolumeIsServedFromItsOwnRoot() async throws {
    let device = FakeAndroid(volumes: ["1234-ABCD"])
    device.state.withLock {
      $0.nodes[FakeAndroid.bytes("/storage/1234-ABCD/card.txt")] = .file(Data("c".utf8), mtime: 9)
    }
    let volume = StorageID(device: ADBFixture.deviceID, key: "volume:1234-ABCD")
    let items = try await ADBFixture.withSession(device) { try await $0.list(.root, in: volume) }
    #expect(items.map(\.path) == [try path("/card.txt")])
  }

  @Test func storagesOfAnotherDeviceOrUnknownVolumesAreNotFound() async throws {
    let other = StorageID(device: DeviceID(serial: "other"), key: "internal")
    let unknown = StorageID(device: ADBFixture.deviceID, key: "volume:FFFF-0000")
    try await ADBFixture.withSession(FakeAndroid()) { session in
      await #expect(throws: TransportError.storageNotFound("internal")) {
        _ = try await session.list(.root, in: other)
      }
      await #expect(throws: TransportError.storageNotFound("volume:FFFF-0000")) {
        _ = try await session.list(.root, in: unknown)
      }
    }
  }

  // MARK: Listing

  @Test func listMapsKindSizeAndDateSorted() async throws {
    let device = FakeAndroid()
    device.addFolder("/DCIM", mtime: 1_700_000_100)
    device.addFile("/b.txt", Data("hello".utf8), mtime: 1_700_000_200)
    device.addFile("/a.txt", Data(), mtime: 1_700_000_300)
    let items = try await ADBFixture.withSession(device) { try await $0.list(.root, in: storage) }
    #expect(
      items == [
        RemoteItem(
          path: try path("/DCIM"), kind: .folder, size: 0,
          modified: Date(timeIntervalSince1970: 1_700_000_100)),
        RemoteItem(
          path: try path("/a.txt"), kind: .file, size: 0,
          modified: Date(timeIntervalSince1970: 1_700_000_300)),
        RemoteItem(
          path: try path("/b.txt"), kind: .file, size: 5,
          modified: Date(timeIntervalSince1970: 1_700_000_200)),
      ])
  }

  /// A name that is not UTF-8 and anything that is neither file nor folder are left out; a
  /// name stored in NFD is listed under its NFC form.
  @Test func listSkipsNamesItCannotAddressAgain() async throws {
    let device = FakeAndroid()
    device.addFile("/keep.txt", Data("k".utf8))
    device.addRaw("/", name: [0x66, 0xFF, 0x2E], node: .file(Data("x".utf8), mtime: 1))
    device.addRaw("/", name: Array("Cafe\u{301}.txt".utf8), node: .file(Data("x".utf8), mtime: 1))
    device.addRaw("/", name: Array("link".utf8), node: .special)
    let items = try await ADBFixture.withSession(device) { try await $0.list(.root, in: storage) }
    #expect(items.map(\.path) == [try path("/Caf\u{E9}.txt"), try path("/keep.txt")])
  }

  @Test(arguments: ["/missing", "/file.txt"])
  func listingAMissingFolderOrAFileIsNotFound(_ folder: String) async throws {
    let device = FakeAndroid()
    device.addFile("/file.txt", Data("f".utf8))
    await #expect(throws: TransportError.notFound(try path(folder))) {
      try await ADBFixture.withSession(device) { _ = try await $0.list(path(folder), in: storage) }
    }
  }

  @Test func itemReportsKindSizeAndDate() async throws {
    let device = FakeAndroid()
    device.addFolder("/Music", mtime: 1_700_000_001)
    device.addFile("/Music/song.mp3", Data(count: 300), mtime: 1_700_000_002)
    let song = try path("/Music/song.mp3")
    let none = try path("/Music/none")
    let (file, folder, root) = try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.notFound(none)) {
        _ = try await session.item(at: none, in: storage)
      }
      return (
        try await session.item(at: song, in: storage),
        try await session.item(at: path("/Music"), in: storage),
        try await session.item(at: .root, in: storage)
      )
    }
    #expect(
      file
        == RemoteItem(
          path: song, kind: .file, size: 300, modified: Date(timeIntervalSince1970: 1_700_000_002)))
    #expect(folder.kind == .folder)
    #expect(root == RemoteItem(path: .root, kind: .folder, size: 0, modified: .distantPast))
  }
}
