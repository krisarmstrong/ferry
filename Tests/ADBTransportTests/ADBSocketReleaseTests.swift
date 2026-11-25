import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// Every connection the transport lets go of is closed, so routine cancellations cannot use up
/// file descriptors on the Mac or `sync:` services on the device. Each test waits for the server
/// to see the connection end, with no deadline but the time limit.
@Suite(.timeLimit(.minutes(1)))
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
      await device.waitUntilNone(.syncs)
    }
  }

  private enum ServerSaw: Equatable { case connection, end }

  /// A stream dropped without `close()` closes its socket. It is dropped where the scope that
  /// holds the only reference to it ends, once the server has the connection.
  @Test func aDroppedStreamClosesItsSocket() async throws {
    let (saw, sees) = AsyncStream.makeStream(of: ServerSaw.self)
    let server = try await FakeADBServer.start { peer in
      sees.yield(.connection)
      _ = try? await peer.stream.read(exactly: 1)
      sees.yield(.end)
    }
    defer { server.stop() }
    var events = saw.makeAsyncIterator()
    do {
      let stream = try await ADBStream.open(port: server.port)
      #expect(await events.next() == .connection)
      withExtendedLifetime(stream) {}
    }
    #expect(await events.next() == .end)
  }
}
