import DeviceKit
import DeviceKitTestSupport
import Foundation

@testable import MTPTransport

/// Shared setup for the `MTPSession` unit tests: one device with one storage.
enum SessionFixture {
  static let deviceID = DeviceID(serial: "SERIAL1")
  static let rawStorage: UInt32 = 0x0001_0001
  static let storage = StorageID(device: deviceID, key: "Internal shared storage|vol1")
  static let root = PathResolver.rootParent

  static func makeDevice(capabilities: DeviceCapabilities = [.move]) -> StubMTPDevice {
    let info = DeviceInfo(id: deviceID, manufacturer: "Acme", model: "Phone")
    let storage = StorageInfo(
      id: Self.storage, description: "Internal shared storage", capacity: 1 << 30, free: 1 << 29)
    return StubMTPDevice(
      info: info, storages: [(raw: rawStorage, info: storage)], capabilities: capabilities)
  }

  static func localFile(_ data: Data) throws -> URL {
    let url = TestScratch.root.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
  }

  static func path(_ string: String) throws -> RemotePath {
    try RemotePath(string)
  }

  static let noProgress: ProgressHandler = { _, _ in true }
}
