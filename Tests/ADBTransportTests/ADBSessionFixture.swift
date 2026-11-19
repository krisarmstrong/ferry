import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// An `ADBSession` on a `FakeAndroid`. The adb routing serial is a Wi-Fi address while the device
/// is known by its `ro.serialno`, as over ADB on Wi-Fi.
enum ADBFixture {
  static let serial = "10.0.0.5:5555"
  static let deviceID = DeviceID(serial: "0123456789abcdef")
  static let storage = StorageID(device: deviceID, key: "internal")
  static let info = DeviceInfo(id: deviceID, manufacturer: "NetAlly", model: "LinkRunner")
  static let noProgress: ProgressHandler = { _, _ in true }

  /// Runs `body` on a session over `device`, then closes both.
  @discardableResult
  static func withSession<T>(
    _ device: FakeAndroid, _ body: (ADBSession) async throws -> T
  ) async throws -> T {
    let server = try await device.serve(serial: serial)
    let session = ADBSession(
      host: ADBHost(port: server.port, locator: ADBHostTests.noAdb), serial: serial,
      transportID: nil, info: info,
      features: ["cmd", "shell_v2", "stat_v2"], method: .usbADB)
    do {
      let result = try await body(session)
      await session.close()
      server.stop()
      return result
    } catch {
      await session.close()
      server.stop()
      throw error
    }
  }

  static func path(_ string: String) throws -> RemotePath { try RemotePath(string) }

  /// A file on the Mac holding `data`, removed by the caller.
  static func localFile(_ data: Data, modified: Date? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ferry-adb-\(UUID()).bin")
    try data.write(to: url)
    if let modified {
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    return url
  }

  /// A folder on the Mac for downloads, removed by the caller.
  static func downloadFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ferry-adb-dl-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Waits for `condition`, which adbd's own clean-up makes true shortly after a transfer ends.
  static func eventually(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}
