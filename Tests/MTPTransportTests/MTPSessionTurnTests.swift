import DeviceKit
import DeviceKitTestSupport
import Foundation
import Testing

@testable import MTPTransport

/// A turn that refuses, as the agent's does for a request cancelled while it queued.
struct RefusedTurn: DeviceTurn {
  func takeTurn() throws(TransportError) { throw .cancelled }
}

/// The session asks for the request's turn once it holds its gate, before any device call.
struct MTPSessionTurnTests {
  @Test func aRefusedTurnTouchesNoDevice() async throws {
    let device = SessionFixture.makeDevice()
    let session = MTPSession(device: device, scratch: TestScratch.root)
    let before = await device.callCount
    await #expect(throws: TransportError.cancelled) {
      try await DeviceTurns.$current.withValue(RefusedTurn()) {
        _ = try await session.list(.root, in: SessionFixture.storage)
      }
    }
    #expect(await device.callCount == before)
    // The session is not lost: the next request lists.
    #expect(try await session.list(.root, in: SessionFixture.storage).isEmpty)
  }
}
