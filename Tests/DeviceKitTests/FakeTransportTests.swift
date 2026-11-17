import DeviceKitTestSupport
import Foundation
import Testing

@testable import DeviceKit

struct FakeTransportTests {
  let deviceID = DeviceID(serial: "FAKE1")
  var storageID: StorageID { StorageID(device: deviceID, key: "Internal|vol0") }

  func makeDevice(capabilities: DeviceCapabilities = [.move, .copy]) -> FakeDevice {
    FakeDevice(
      info: DeviceInfo(id: deviceID, manufacturer: "Fake", model: "Phone"),
      storages: [
        StorageInfo(id: storageID, description: "Internal", capacity: 1_000, free: 900)
      ],
      capabilities: capabilities)
  }

  func tempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
  }

  @Test func unknownStorageIsStorageNotFound() async throws {
    let device = makeDevice()
    let unknown = StorageID(device: deviceID, key: "SD|vol9")
    await #expect(throws: TransportError.storageNotFound(unknown.key)) {
      _ = try await device.item(at: .root, in: unknown)
    }
  }

  @Test func seedListAndItem() async throws {
    let device = makeDevice()
    try await device.seed(RemotePath("/DCIM/a.jpg"), in: storageID, contents: Data([1, 2, 3, 4]))

    let root = try await device.list(.root, in: storageID)
    #expect(root.map(\.path) == [try RemotePath("/DCIM")])
    #expect(root.first?.kind == .folder)

    let dcim = try await device.list(RemotePath("/DCIM"), in: storageID)
    #expect(dcim.count == 1)
    #expect(dcim.first?.kind == .file)
    #expect(dcim.first?.size == 4)

    let item = try await device.item(at: RemotePath("/DCIM/a.jpg"), in: storageID)
    #expect(item.size == 4)
  }

  @Test func uploadRejectsExisting() async throws {
    let device = makeDevice()
    let path = try RemotePath("/a.txt")
    try await device.seed(path, in: storageID, contents: Data([1]))
    let file = try tempFile(Data([2]))
    await #expect(throws: TransportError.alreadyExists(path)) {
      _ = try await device.upload(from: file, to: path, in: storageID) { _, _ in true }
    }
  }

  @Test func fakeLockedDeviceThrowsDeviceLocked() async throws {
    let device = makeDevice()
    await device.setLocked(true)
    await #expect(throws: TransportError.deviceLocked) {
      _ = try await device.storages()
    }
  }

  @Test func failUploadLeavesPartialObject() async throws {
    let device = makeDevice()
    let path = try RemotePath("/big.bin")
    await device.failUpload(afterBytes: 3, with: .deviceDisconnected)
    let file = try tempFile(Data(repeating: 7, count: 10))
    await #expect(throws: TransportError.deviceDisconnected) {
      _ = try await device.upload(from: file, to: path, in: storageID) { _, _ in true }
    }
    #expect(await device.allPaths(in: storageID).contains(path))
    #expect(await device.contents(of: path, in: storageID)?.count == 3)
  }

  @Test func capabilityWithoutMoveThrowsUnsupported() async throws {
    let device = makeDevice(capabilities: [])
    try await device.seed(RemotePath("/a.txt"), in: storageID, contents: Data([1]))
    await #expect(throws: TransportError.unsupported("move")) {
      _ = try await device.move(RemotePath("/a.txt"), toFolder: .root, in: storageID)
    }
  }

  @Test func truncateUploadsKeepsOnlyPrefix() async throws {
    let device = makeDevice()
    await device.truncateUploads(to: 2)
    let file = try tempFile(Data([1, 2, 3, 4]))
    let path = try RemotePath("/t.bin")
    let item = try await device.upload(from: file, to: path, in: storageID) { _, _ in true }
    #expect(item.size == 2)
    #expect(await device.contents(of: path, in: storageID) == Data([1, 2]))
  }

  @Test func failRenameIsOneShotAndClearable() async throws {
    let device = makeDevice()
    try await device.seed(RemotePath("/a.txt"), in: storageID, contents: Data([1]))
    await device.failRename(with: .deviceBusy)
    await #expect(throws: TransportError.deviceBusy) {
      _ = try await device.rename(RemotePath("/a.txt"), to: "b.txt", in: storageID)
    }
    let renamed = try await device.rename(RemotePath("/a.txt"), to: "b.txt", in: storageID)
    #expect(renamed.path == (try RemotePath("/b.txt")))
    await device.failRename(with: .deviceBusy)
    await device.failRename(with: nil)
    _ = try await device.rename(RemotePath("/b.txt"), to: "c.txt", in: storageID)
  }

  @Test func downloadWritesFileAndHonoursCancel() async throws {
    let device = makeDevice()
    let path = try RemotePath("/a.bin")
    try await device.seed(path, in: storageID, contents: Data([9, 8, 7]))
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dest) }
    try await device.download(path, in: storageID, to: dest, replacing: false) { _, _ in true }
    #expect(try Data(contentsOf: dest) == Data([9, 8, 7]))
    await #expect(throws: TransportError.cancelled) {
      try await device.download(path, in: storageID, to: dest, replacing: true) { _, _ in false }
    }
  }

  @Test func downloadReplacesOnlyWhenAsked() async throws {
    let device = makeDevice()
    let path = try RemotePath("/a.bin")
    try await device.seed(path, in: storageID, contents: Data([9, 8, 7]))
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dest) }
    try Data([1]).write(to: dest)

    await #expect(throws: TransportError.alreadyExists(path)) {
      try await device.download(path, in: storageID, to: dest, replacing: false) { _, _ in true }
    }
    #expect(try Data(contentsOf: dest) == Data([1]))
    try await device.download(path, in: storageID, to: dest, replacing: true) { _, _ in true }
    #expect(try Data(contentsOf: dest) == Data([9, 8, 7]))
  }

  @Test func deleteFolderIsRecursiveAndMoveWorks() async throws {
    let device = makeDevice()
    try await device.seed(RemotePath("/d/x/a.txt"), in: storageID, contents: Data([1]))
    _ = try await device.makeFolder(RemotePath("/e"), in: storageID)
    let moved = try await device.move(
      RemotePath("/d/x/a.txt"), toFolder: RemotePath("/e"), in: storageID)
    #expect(moved.path == (try RemotePath("/e/a.txt")))
    try await device.delete(RemotePath("/d"), in: storageID)
    let paths = await device.allPaths(in: storageID)
    #expect(!paths.contains(try RemotePath("/d/x")))
    #expect(paths.contains(try RemotePath("/e/a.txt")))
  }

  @Test func transportOpensKnownDevicesOnly() async throws {
    let transport = FakeTransport(devices: [makeDevice()])
    #expect(try await transport.connectedDevices().map(\.id) == [deviceID])
    let session = try await transport.open(deviceID)
    #expect(session.info.id == deviceID)
    let missing = DeviceID(serial: "nope")
    await #expect(throws: TransportError.deviceNotFound(missing)) {
      _ = try await transport.open(missing)
    }
  }
}
