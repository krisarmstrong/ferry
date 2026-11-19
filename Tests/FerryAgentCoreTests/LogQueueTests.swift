import FerryIPC
import Foundation
import Testing

@testable import ADBTransport
@testable import FerryAgentCore

/// The queue between the device and the client: bounded, newest lines kept, dropped lines
/// counted.
@Suite(.timeLimit(.minutes(1)))
struct LogQueueTests {
  @Test func theQueueKeepsTheNewestLinesWithinItsLimit() async {
    let queue = LogQueue(maxLines: 4, maxBytes: 1_000)
    await queue.push((0..<10).map { Data("l\($0)".utf8) })
    let batch = await queue.take(maxLines: 100, maxBytes: 1_000)
    #expect(batch?.lines == ["l6", "l7", "l8", "l9"])
    #expect(batch?.skipped == 6)
    await queue.push([Data("next".utf8)])
    #expect(
      await queue.take(maxLines: 100, maxBytes: 1_000) == LogBatch(lines: ["next"], skipped: 0))
  }

  @Test func theQueueKeepsWithinItsByteLimit() async {
    let queue = LogQueue(maxLines: 1_000, maxBytes: 10)
    await queue.push(["aaaa", "bbbb", "cccc"].map { Data($0.utf8) })
    let batch = await queue.take(maxLines: 100, maxBytes: 1_000)
    #expect(batch?.lines == ["bbbb", "cccc"])
    #expect(batch?.skipped == 1)
  }

  @Test func aTakeEndsAtItsBatchLimitsButAlwaysTakesOneLine() async {
    let queue = LogQueue(maxLines: 100, maxBytes: 1_000)
    await queue.push(["aaaa", "bbbb", "cccc"].map { Data($0.utf8) })
    #expect(await queue.take(maxLines: 2, maxBytes: 1_000)?.lines == ["aaaa", "bbbb"])
    #expect(await queue.take(maxLines: 10, maxBytes: 1)?.lines == ["cccc"])
  }

  @Test func aTakeWaitsForLinesAndEndsWhenTheQueueIsFinished() async {
    let queue = LogQueue(maxLines: 10, maxBytes: 1_000)
    let waiting = Task { await queue.take(maxLines: 10, maxBytes: 100) }
    try? await Task.sleep(for: .milliseconds(20))
    await queue.push([Data("hello".utf8)])
    #expect(await waiting.value?.lines == ["hello"])
    let ending = Task { await queue.take(maxLines: 10, maxBytes: 100) }
    try? await Task.sleep(for: .milliseconds(20))
    await queue.finish(.connectionClosed)
    #expect(await ending.value == nil)
    #expect(await queue.failure == .connectionClosed)
  }

  @Test func linesQueuedBeforeTheEndAreStillTaken() async {
    let queue = LogQueue(maxLines: 10, maxBytes: 1_000)
    await queue.push([Data("last".utf8)])
    await queue.finish(nil)
    #expect(await queue.take(maxLines: 10, maxBytes: 100)?.lines == ["last"])
    #expect(await queue.take(maxLines: 10, maxBytes: 100) == nil)
  }
}
