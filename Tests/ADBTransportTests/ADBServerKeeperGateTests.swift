import Darwin
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
}
