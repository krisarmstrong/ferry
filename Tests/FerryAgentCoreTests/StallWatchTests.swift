import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// A move may take long, as a copy does, but must not stop: the watch judges it by its
/// progress, never its total time.
@Suite(.timeLimit(.minutes(1)))
struct StallWatchTests {
  /// The device stops answering in the middle of a move: the move fails, as busy, once the
  /// limit passes with no progress, rather than holding Finder's request forever.
  @Test func aMoveThatStopsIsFailed() async throws {
    let device = await makeDevice("A")
    let storage = storageID(device)
    try await device.seed(try path("/a.txt"), in: storage, contents: Data("a".utf8))
    _ = try await device.makeFolder(try path("/B"), in: storage)
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    let (answered, answer) = AsyncStream.makeStream(of: Void.self)
    await device.onNextMove {
      for await _ in answered { return }
    }
    let move = AgentRequest.move(
      domain: domain, id: try await harness.id(try path("/a.txt"), in: domain),
      toFolder: try await harness.id(try path("/B"), in: domain))

    let reply = await harness.clock.advancing(by: .seconds(10)) {
      await harness.service.handle(move, file: nil)
    }

    #expect(reply == .failure(.deviceBusy))
    answer.finish()
  }

  /// A long transfer that keeps making progress runs to its end, past the limit many times.
  @Test func workThatKeepsBeatingIsNotStopped() async throws {
    let clock = ManualClock()
    let result = await clock.advancing(by: .seconds(10)) {
      () async -> Result<Int, TransportError> in
      do throws(TransportError) {
        return .success(
          try await StallWatch.run(limit: .seconds(60), clock: clock) {
            () async throws(TransportError) -> Int in
            for _ in 0..<30 {
              TransferHeartbeat.current?.beat()
              try? await clock.sleep(for: .seconds(10))
            }
            return 7
          })
      } catch {
        return .failure(error)
      }
    }
    #expect(result == .success(7))
  }
}
