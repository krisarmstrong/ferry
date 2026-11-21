import Darwin
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

/// A wedged server (stopped, or its loop stuck) accepts the connection and never answers. The
/// agent waits for the replacement before its XPC listener is up, and connects wait behind a
/// replacement, so nothing the keeper asks of a server may wait for it unbounded. The limits run
/// on a ManualClock that moves only while the keeper waits on it, so each test ends by its
/// limits, never by how fast the machine is.
struct ADBServerKeeperBoundTests {
  typealias Keeper = ADBServerKeeperTests
  typealias Gate = ADBServerKeeperGateTests

  @Test(.timeLimit(.minutes(1)))
  func aKillThatNeverReturnsEndsTheOrphanReplacement() async throws {
    let fakes = Keeper.Fakes()
    let record = Keeper.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try Gate.recordedOrphan(fakes, record: record)
    fakes { $0.killHangs = true }
    let clock = ManualClock()
    let keeper = Keeper.keeper(fakes, record: record, clock: clock)
    // It ends, by the kill's limit and then the exit wait's, and reports the stop it began.
    #expect(await clock.advancing(by: .milliseconds(10)) { await keeper.replaceRecordedOrphan() })
  }

  /// Connects wait behind a replacement: one stuck in its kill must not hold them for good.
  @Test(.timeLimit(.minutes(1)))
  func aKillThatNeverReturnsLetsCommandsRunAgain() async throws {
    let fakes = Keeper.Fakes()
    Gate.ferryServerListening(fakes)
    fakes { $0.killHangs = true }
    let clock = ManualClock()
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile(), clock: clock)
    _ = await clock.advancing(by: .milliseconds(10)) {
      await keeper.replaceFerryServer(fetched: Keeper.adb)
    }
    let ran = try await keeper.whileServing { () async throws(ADBError) in true }
    #expect(ran)
  }

  @Test(.timeLimit(.minutes(1)))
  func aServerThatNeverAnswersEndsTheStart() async {
    let fakes = Keeper.Fakes()
    fakes { $0.answersHang = true }
    let clock = ManualClock()
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile(), clock: clock)
    let error = await clock.advancing(by: .milliseconds(10)) {
      await Keeper.outcome { () async throws(ADBError) in try await keeper.start(Keeper.adb) }
    }
    #expect(error == .failed("the adb server did not answer in time"))
  }

  /// Two replacements waiting on the same running command both go on once it ends.
  @Test(.timeLimit(.minutes(1)))
  func twoReplacementsWaitingForACommandBothEnd() async throws {
    let fakes = Keeper.Fakes()
    let record = Keeper.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try Gate.recordedOrphan(fakes, record: record)
    fakes { $0.googleADB = [9] }
    let keeper = Keeper.keeper(fakes, record: record)
    let (commandHeld, holding) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let command = Task {
      try await keeper.whileServing { () async throws(ADBError) in
        holding.yield()
        for await _ in released { break }
      }
    }
    for await _ in commandHeld { break }
    let orphan = Task { await keeper.replaceRecordedOrphan() }
    let cutOff = Task { await keeper.replaceFerryServer(fetched: Keeper.adb) }
    try await Task.sleep(for: .milliseconds(100))
    release.yield()
    try await command.value
    // Both end; a hang runs into the time limit.
    _ = await orphan.value
    _ = await cutOff.value
    #expect(fakes { $0.kills } == 1)
  }
}
