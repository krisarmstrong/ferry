import Darwin
import Foundation
import Testing

@testable import ADBTransport

/// A wedged server (stopped, or its loop stuck) accepts the connection and never answers. The
/// agent waits for the replacement before its XPC listener is up, and connects wait behind a
/// replacement, so nothing the keeper asks of a server may wait for it unbounded.
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
    let began = ContinuousClock.now
    _ = await Keeper.keeper(fakes, record: record).replaceRecordedOrphan()
    #expect(began.duration(to: .now) < .seconds(5))
  }

  /// Connects wait behind a replacement: one stuck in its kill must not hold them for good.
  @Test(.timeLimit(.minutes(1)))
  func aKillThatNeverReturnsLetsCommandsRunAgain() async throws {
    let fakes = Keeper.Fakes()
    Gate.ferryServerListening(fakes)
    fakes { $0.killHangs = true }
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile())
    _ = await keeper.replaceFerryServer(fetched: Keeper.adb)
    let ran = try await keeper.whileServing { () async throws(ADBError) in true }
    #expect(ran)
  }

  @Test(.timeLimit(.minutes(1)))
  func aServerThatNeverAnswersEndsTheStart() async {
    let fakes = Keeper.Fakes()
    fakes { $0.answersHang = true }
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile())
    let began = ContinuousClock.now
    _ = await Keeper.outcome { () async throws(ADBError) in try await keeper.start(Keeper.adb) }
    #expect(began.duration(to: .now) < .seconds(5))
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
    let ended = await ADBServerKeeper.race(.seconds(5)) {
      _ = await orphan.value
      _ = await cutOff.value
      return true
    }
    #expect(ended == true)
    #expect(fakes { $0.kills } == 1)
  }
}
