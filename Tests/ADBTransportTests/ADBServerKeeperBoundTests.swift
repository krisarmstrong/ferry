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
}
