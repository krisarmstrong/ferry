import DeviceKit
import Foundation
import Testing

@testable import MTPTransport

/// Runs against a real, unlocked Android device. These write to the device, so they are off
/// unless `FERRY_DEVICE_TESTS=1`. Each test opens the one phone, so they run one at a time.
@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["FERRY_DEVICE_TESTS"] == "1"), .serialized)
struct MTPDeviceIntegrationTests {
  func openFirstDevice() throws -> MTPDevice {
    let raw = try #require(try MTPDevice.detect().first, "no MTP device attached")
    return try MTPDevice(opening: raw)
  }

  @Test func detectsAndOpens() async throws {
    let device = try openFirstDevice()
    #expect(!device.info.id.serial.isEmpty)
    _ = await device.capabilities()
  }

  /// Manual: run with the phone locked.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["FERRY_DEVICE_LOCKED"] == "1"))
  func storagesEmptyMapsToLocked() async throws {
    let device = try openFirstDevice()
    await #expect(throws: TransportError.deviceLocked) {
      _ = try await device.storages()
    }
  }

  @Test func roundTripSmallFile() async throws {
    let device = try openFirstDevice()
    let storage = try #require(try await device.storages().first).raw
    let root = PathResolver.rootParent

    let folderName = "ferry-test-\(UUID().uuidString)"
    let folder = try await device.createFolder(name: folderName, parent: root, storage: storage)
    do {
      let payload = Data((0..<16).map { UInt8($0) })
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      try payload.write(to: source)
      defer { try? FileManager.default.removeItem(at: source) }

      let id = try await device.upload(
        from: source, name: "probe.bin", parent: folder, storage: storage
      ) { _, _ in true }

      let listed = try await device.list(storage: storage, parent: folder)
      #expect(listed.map(\.name) == ["probe.bin"])
      #expect(listed.first?.size == 16)

      let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: copy) }
      try await device.download(objectID: id, to: copy) { _, _ in true }
      #expect(try Data(contentsOf: copy) == payload)

      try await device.rename(objectID: id, to: "renamed.bin")
      #expect(try await device.metadata(objectID: id).name == "renamed.bin")
    } catch {
      try? await device.delete(objectID: folder)
      throw error
    }
    try await device.delete(objectID: folder)
  }
}
