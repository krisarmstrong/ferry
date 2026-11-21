import Darwin
import DeviceKitTestSupport
import Foundation
import Testing

@testable import ADBTransport

/// An adb client command started with no server answering forks a daemon of its own, which
/// outlives the agent. So a replacement never stops the server under a command that has
/// checked for it, and no command starts while the replacement runs.
struct ADBServerKeeperGateTests {
  typealias Keeper = ADBServerKeeperTests

  /// A server running Ferry's adb on the port, which `replaceFerryServer` replaces.
  static func ferryServerListening(_ fakes: Keeper.Fakes) {
    fakes { state in
      state.answering = true
      state.listener = 33
      state.paths[33] = Keeper.adb.path
      state.googleADB = [33]
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aReplacementWaitsForACommandUnderWay() async throws {
    let fakes = Keeper.Fakes()
    Self.ferryServerListening(fakes)
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile())
    let (commandHeld, holding) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let command = Task {
      try await keeper.whileServing { () async throws(ADBError) -> Int in
        holding.yield()
        for await _ in released { break }
        return fakes { $0.kills }
      }
    }
    for await _ in commandHeld { break }
    let replacing = Task { await keeper.replaceFerryServer(fetched: Keeper.adb) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(fakes { $0.kills } == 0)
    release.yield()
    #expect(try await command.value == 0)
    #expect(await replacing.value)
    #expect(fakes { $0.kills } == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandWaitsForAReplacementUnderWay() async throws {
    let fakes = Keeper.Fakes()
    Self.ferryServerListening(fakes)
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile())
    let (commandHeld, holding) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    // Holds the replacement waiting, so the second command arrives while it is under way.
    let first = Task {
      try await keeper.whileServing { () async throws(ADBError) in
        holding.yield()
        for await _ in released { break }
      }
    }
    for await _ in commandHeld { break }
    let replacing = Task { await keeper.replaceFerryServer(fetched: Keeper.adb) }
    try await Task.sleep(for: .milliseconds(50))
    let second = Task {
      try await keeper.whileServing { () async throws(ADBError) -> Int in fakes { $0.kills } }
    }
    try await Task.sleep(for: .milliseconds(50))
    release.yield()
    try await first.value
    #expect(await replacing.value)
    #expect(try await second.value == 1)
  }

  // MARK: Only the server checked is stopped (review I3)

  static func recordedOrphan(_ fakes: Keeper.Fakes, record: URL) throws {
    try ADBServerRecord(pid: 9, started: 5, path: Keeper.adb.path).save(to: record)
    fakes { state in
      state.answering = true
      state.started[9] = 5
      state.paths[9] = Keeper.adb.path
      state.listener = 9
    }
  }

  /// The recorded process still runs, but another server holds the port.
  @Test func aRecordedProcessNotListeningIsNotStopped() async throws {
    let fakes = Keeper.Fakes()
    let record = Keeper.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try Self.recordedOrphan(fakes, record: record)
    fakes { $0.listener = 77 }
    #expect(await Keeper.keeper(fakes, record: record).replaceRecordedOrphan() == false)
    #expect(fakes { $0.kills } == 0)
  }

  /// The listener changed while the replacement waited for a command: nothing is stopped.
  @Test(.timeLimit(.minutes(1)))
  func aListenerThatChangesWhileWaitingIsNotStopped() async throws {
    let fakes = Keeper.Fakes()
    let record = Keeper.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try Self.recordedOrphan(fakes, record: record)
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
    let replacing = Task { await keeper.replaceRecordedOrphan() }
    try await Task.sleep(for: .milliseconds(50))
    fakes { $0.listener = 77 }
    release.yield()
    try await command.value
    #expect(await replacing.value == false)
    #expect(fakes { $0.kills } == 0)
  }

  /// The program on disk is Ferry's, but the running code is not Google's adb.
  @Test func aListenerNotRunningGooglesADBIsNotStopped() async {
    let fakes = Keeper.Fakes()
    Self.ferryServerListening(fakes)
    fakes { $0.googleADB = [] }
    let keeper = Keeper.keeper(fakes, record: Keeper.recordFile())
    #expect(await keeper.replaceFerryServer(fetched: Keeper.adb) == false)
    #expect(fakes { $0.kills } == 0)
  }

  // MARK: The record during a replacement (review I4, M1)

  /// The trackers start the new server while the old one is still exiting: the new server's
  /// record stays, and the stop ends when the old PID is gone, not when the port falls silent.
  @Test(.timeLimit(.minutes(1)))
  func aServerStartedDuringTheStopKeepsItsRecord() async throws {
    let fakes = Keeper.Fakes()
    let record = Keeper.recordFile()
    defer { try? FileManager.default.removeItem(at: record) }
    try Self.recordedOrphan(fakes, record: record)
    let restart = Box<ADBServerKeeper?>(nil)
    // Limits the stop can never reach in this test: ending when the port falls silent (never,
    // the new server answers) would run into the time limit, not pass by the clock. Time moves
    // only by the test's hand, so no limit runs out on a loaded machine either.
    let clock = ManualClock()
    let keeper = Keeper.keeper(
      fakes, record: record, exits: .milliseconds(300), limit: .seconds(3600),
      callLimit: .seconds(3600), clock: clock,
      whileStopping: { try? await restart.value?.start(Keeper.adb) })
    await restart.set(keeper)
    #expect(await clock.advancing(by: .milliseconds(10)) { await keeper.replaceRecordedOrphan() })
    #expect(fakes { $0.spawned.count } == 1)
    #expect(ADBServerRecord.load(record)?.pid == 4242)
  }
}
