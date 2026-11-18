import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// The `ADBError` → `TransportError` table on `ADBSession.failure(_:_:)`.
struct ADBSessionErrorTests {
  static let step = ADBSession.Step("delete", .root)

  @Test(
    arguments: [
      (ADBError.deviceGone("S"), TransportError.deviceDisconnected),
      (.serverUnavailable, .deviceDisconnected),
      (.failed("device offline"), .deviceDisconnected),
      (
        .failed("device unauthorized.\nThis adb server's $ADB_VENDOR_KEYS is not set"),
        .deviceDisconnected
      ),
      (.cancelled, .cancelled),
      (.invalidArgument("/storage/emulated/0/x"), .invalidName("/")),
      (.failed("open failed: No such file or directory"), .notFound(.root)),
      (.failed("write failed: No space left on device"), .insufficientSpace(needed: 0, free: 0)),
      (
        .failed("couldn't create file: Permission denied"),
        .io("delete failed: couldn't create file: Permission denied")
      ),
      (.connectionClosed, .io("delete failed: connectionClosed")),
      (.protocolViolation("bad"), .io("delete failed: protocolViolation(\"bad\")")),
    ])
  func errorsMapWhileTheDeviceIsThere(_ error: ADBError, _ expected: TransportError) async throws {
    let mapped = try await ADBFixture.withSession(FakeAndroid()) { session in
      await session.failure(error, Self.step)
    }
    #expect(mapped == expected)
  }

  /// A failure Ferry cannot explain, once the server no longer knows the device, is the device
  /// leaving rather than an I/O error.
  @Test(
    arguments: [
      ADBError.connectionClosed, .protocolViolation("bad"), .failed("Connection reset by peer"),
    ])
  func anUnexplainedFailureOfAGoneDeviceIsADisconnect(_ error: ADBError) async throws {
    let device = FakeAndroid()
    let mapped = try await ADBFixture.withSession(device) { session in
      device.unplug()
      return await session.failure(error, Self.step)
    }
    #expect(mapped == .deviceDisconnected)
  }

  /// A path too long for the sync service is a name the device cannot take.
  @Test func aPathTooLongForSyncIsAnInvalidName() async throws {
    let path = try RemotePath.root.appending(String(repeating: "n", count: 1100))
    let file = try ADBFixture.localFile(Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect(throws: TransportError.invalidName(path.description)) {
      try await ADBFixture.withSession(FakeAndroid()) { session in
        _ = try await session.upload(
          from: file, to: path, in: ADBFixture.storage, progress: ADBFixture.noProgress)
      }
    }
  }
}
