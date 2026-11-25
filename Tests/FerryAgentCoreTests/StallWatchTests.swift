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
  /// The copy a move makes stops in the middle: the move fails, as busy, once the limit passes
  /// with no progress, rather than holding Finder's request forever.
  @Test func aMoveCopyThatStopsIsFailed() async throws {
    let device = await makeDevice("A")
    let storage = storageID(device)
    try await device.seed(try path("/a.txt"), in: storage, contents: Data("a".utf8))
    _ = try await device.makeFolder(try path("/B"), in: storage)
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    let (answered, answer) = AsyncStream.makeStream(of: Void.self)
    // As `MTPSession.copyThenDelete`: the copy arms the heartbeat, then never beats.
    await device.onNextMove {
      TransferHeartbeat.current?.arm()
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

  /// A native MoveObject reports nothing while the device works, and across storages it copies
  /// the data and may take minutes: it is never failed for that, or the device would be left
  /// mid-move while Finder heard "busy".
  @Test func aLongNativeMoveIsNotFailed() async throws {
    let device = await makeDevice("A")
    let storage = storageID(device)
    try await device.seed(try path("/a.txt"), in: storage, contents: Data("a".utf8))
    _ = try await device.makeFolder(try path("/B"), in: storage)
    let harness = try AgentHarness(devices: [device])
    defer { harness.finish() }
    let domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    let (started, start) = AsyncStream.makeStream(of: Void.self)
    let (answered, answer) = AsyncStream.makeStream(of: Void.self)
    await device.onNextMove {
      start.yield()
      for await _ in answered { return }
    }
    let move = AgentRequest.move(
      domain: domain, id: try await harness.id(try path("/a.txt"), in: domain),
      toFolder: try await harness.id(try path("/B"), in: domain))
    let reply = Task { await harness.service.handle(move, file: nil) }

    var moving = started.makeAsyncIterator()
    _ = await moving.next()
    // Three minutes of silence from the device, ten seconds at a time.
    for _ in 0..<18 {
      await harness.clock.waitForSleeper()
      await harness.clock.advance(by: .seconds(10))
    }
    answer.finish()

    guard case .entry(let entry) = await reply.value else {
      Issue.record("expected the moved item")
      return
    }
    #expect(entry.item.path == (try path("/B/a.txt")))
  }

  /// A long transfer that keeps making progress runs to its end, past the limit many times.
  /// The test beats for it and moves the clock itself, 50 s at a time, so no 60 s goes by
  /// without a beat whatever order the tasks run in.
  @Test func workThatKeepsBeatingIsNotStopped() async throws {
    let clock = ManualClock()
    let (started, start) = AsyncStream.makeStream(of: TransferHeartbeat.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let work = Task { () async -> Result<Int, TransportError> in
      do throws(TransportError) {
        return .success(
          try await StallWatch.run(limit: .seconds(60), clock: clock) {
            () async throws(TransportError) -> Int in
            if let heartbeat = TransferHeartbeat.current { start.yield(heartbeat) }
            for await _ in released {}
            return 7
          })
      } catch {
        return .failure(error)
      }
    }
    var beats = started.makeAsyncIterator()
    let heartbeat = try #require(await beats.next())
    await clock.waitForSleeper()
    for _ in 0..<10 {
      heartbeat.beat()
      await clock.advance(by: .seconds(50))
    }
    release.finish()

    #expect(await work.value == .success(7))
  }
}
