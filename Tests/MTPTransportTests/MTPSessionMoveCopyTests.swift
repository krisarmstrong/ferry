import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// A move on a device without MoveObject is a copy of the whole file, then a delete of the
/// source: the copy is a transfer, and the delete must not lose anything.
struct MTPSessionMoveCopyTests {
  /// The copy a move makes on a device without MoveObject is a whole transfer: the request's
  /// cancel stops it, leaving the source where it was and no partial copy.
  @Test func aCancelledMoveFallbackKeepsTheSource() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    await device.addFile("a.txt", parent: SessionFixture.root, data: Data("payload".utf8))
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.cancelled) {
      try await DeviceTurns.$current.withValue(CancelledTurn()) {
        _ = try await session.move(
          SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"),
          in: SessionFixture.storage)
      }
    }
    #expect(await device.children(of: SessionFixture.root) == ["B", "a.txt"])
    #expect(await device.children(of: dest) == [])
    // Stopped while the copy came down to the Mac: nothing went up.
    #expect(
      await device.calls.contains {
        if case .upload = $0 { return true }
        return false
      } == false)
  }

  /// The source changed on the device while its copy was made (an app wrote to it): it is not
  /// deleted, since the copy is of the old contents. Both stay, and the move reports it.
  @Test func aSourceChangedDuringTheMoveCopyIsKept() async throws {
    let device = SessionFixture.makeDevice(capabilities: [])
    let source = await device.addFile(
      "a.txt", parent: SessionFixture.root, data: Data("payload".utf8))
    let dest = await device.addFolder("B", parent: SessionFixture.root)
    await device.onUpload { _ in await device.replaceData(of: source, with: Data("rewritten".utf8))
    }
    let session = MTPSession(device: device, scratch: TestScratch.root)

    await #expect(throws: TransportError.changedOnDevice(try SessionFixture.path("/a.txt"))) {
      _ = try await session.move(
        SessionFixture.path("/a.txt"), toFolder: SessionFixture.path("/B"),
        in: SessionFixture.storage)
    }
    #expect(await device.objects[source]?.data == Data("rewritten".utf8))
    #expect(await device.children(of: dest) == ["a.txt"])
  }
}

/// A request whose client has given up.
private struct CancelledTurn: DeviceTurn {
  func takeTurn() throws(TransportError) {}
  var isCancelled: Bool { true }
}
