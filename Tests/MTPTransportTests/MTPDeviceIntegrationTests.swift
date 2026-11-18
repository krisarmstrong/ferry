import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// Runs against a real, unlocked Android device. These write to the device, so they are off
/// unless `FERRY_DEVICE_TESTS=1`. Each test opens the one phone, so they run one at a time.
extension DeviceTests {
  @Suite struct MTPDeviceIntegrationTests {
    func openFirstDevice() async throws -> MTPDevice {
      let candidate = try #require(
        try USBRegistry.attached().first { MTPTransport.candidacy(of: $0) == .mtp },
        "no MTP device attached")
      let raw = try #require(MTPDeviceTable.rawDevice(for: candidate))
      return try await MTPDevice.open(raw, registryID: candidate.registryID)
    }

    @Test func detectsAndOpens() async throws {
      let device = try await openFirstDevice()
      #expect(!device.info.id.serial.isEmpty)
      _ = await device.capabilities()
      await device.close()
    }

    /// Manual: run with the phone locked.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FERRY_DEVICE_LOCKED"] == "1"))
    func storagesEmptyMapsToLocked() async throws {
      let device = try await openFirstDevice()
      await #expect(throws: TransportError.deviceLocked) {
        _ = try await device.storages()
      }
      await device.close()
    }

    @Test func roundTripSmallFile() async throws {
      let device = try await openFirstDevice()
      do {
        try await roundTrip(on: device)
      } catch {
        await device.close()
        throw error
      }
      await device.close()
    }

    func roundTrip(on device: MTPDevice) async throws {
      let storage = try #require(try await device.storages().first).raw
      let root = PathResolver.rootParent

      let folderName = "ferry-test-\(UUID().uuidString)"
      let folder = try await device.createFolder(name: folderName, parent: root, storage: storage)
      do {
        let payload = Data((0..<16).map { UInt8($0) })
        let source = TestScratch.root
          .appendingPathComponent(UUID().uuidString)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let id = try await device.upload(
          from: source, name: "probe.bin", parent: folder, storage: storage
        ) { _, _ in true }

        let listed = try await device.list(storage: storage, parent: folder)
        #expect(listed.map(\.name) == ["probe.bin"])
        #expect(listed.first?.size == 16)

        let copy = TestScratch.root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try await device.download(objectID: id, to: copy) { _, _ in true }
        #expect(try Data(contentsOf: copy) == payload)

        try await device.rename(objectID: id, to: "renamed.bin")
        #expect(try await device.metadata(objectID: id).name == "renamed.bin")
      } catch {
        try? await removeFolder(folder, storage: storage, on: device)
        throw error
      }
      try await removeFolder(folder, storage: storage, on: device)
    }

    /// Deletes `folder` and the files in it, since an MTP device need not delete a non-empty
    /// folder.
    func removeFolder(_ folder: UInt32, storage: UInt32, on device: MTPDevice) async throws {
      for child in try await device.list(storage: storage, parent: folder) {
        try await device.delete(objectID: child.objectID)
      }
      try await device.delete(objectID: folder)
    }
  }
}
