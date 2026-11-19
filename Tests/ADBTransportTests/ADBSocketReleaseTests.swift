import DeviceKit
import Foundation
import Testing
import os

@testable import ADBTransport

/// Every connection the transport lets go of is closed, so routine cancellations cannot use up
/// file descriptors on the Mac or `sync:` services on the device.
struct ADBSocketReleaseTests {
  let storage = ADBFixture.storage

  /// An operation in a cancelled task fails before it writes anything, which leaves its sync
  /// connection intact; the session lets that connection go, and it is closed with it.
  @Test func aCancelledOperationClosesItsSyncConnection() async throws {
    let device = FakeAndroid()
    device.addFile("/a.txt", Data("a".utf8))
    try await ADBFixture.withSession(device) { session in
      _ = try await session.list(.root, in: storage)
      #expect(device.openSyncs == 1)
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await session.item(at: RemotePath("/a.txt"), in: storage)
      }
      await #expect(throws: TransportError.cancelled) { _ = try await cancelled.value }
      #expect(try await ADBFixture.eventually { device.openSyncs == 0 })
    }
  }

  /// A stream dropped without `close()` closes its socket.
  @Test func aDroppedStreamClosesItsSocket() async throws {
    let closed = OSAllocatedUnfairLock(initialState: false)
    let server = try await FakeADBServer.start { peer in
      _ = try? await peer.stream.read(exactly: 1)
      closed.withLock { $0 = true }
    }
    defer { server.stop() }
    var stream: ADBStream? = try await ADBStream.open(port: server.port)
    #expect(stream != nil)
    stream = nil
    #expect(try await ADBFixture.eventually { closed.withLock { $0 } })
  }
}
