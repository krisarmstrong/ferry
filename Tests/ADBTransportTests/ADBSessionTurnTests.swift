import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// A turn that refuses, as the agent's does for a request cancelled while it queued.
private struct RefusedTurn: DeviceTurn {
  func takeTurn() throws(TransportError) { throw .cancelled }
}

/// The session asks for the request's turn once it holds its gate, before any device call.
@Suite(.timeLimit(.minutes(1)))
struct ADBSessionTurnTests {
  @Test func aRefusedTurnTouchesNoDevice() async throws {
    let device = FakeAndroid()
    try await ADBFixture.withSession(device) { session in
      await #expect(throws: TransportError.cancelled) {
        try await DeviceTurns.$current.withValue(RefusedTurn()) {
          _ = try await session.makeFolder(ADBFixture.path("/New"), in: ADBFixture.storage)
        }
      }
    }
    #expect(device.changes.isEmpty)
    #expect(device.node(absolute: "/sdcard/New") == nil)
  }
}
