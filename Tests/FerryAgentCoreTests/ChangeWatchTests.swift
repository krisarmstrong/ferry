import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryAgentCore

/// A switch a test flips while the code under test reads it.
private final class Switch: Sendable {
  private let value = Mutex(false)
  var isOn: Bool { value.withLock { $0 } }
  func set(_ isOn: Bool) { value.withLock { $0 = isOn } }
}

/// A device with folders a client listed, and the change watch over them with its own clock, a
/// switch for "a transfer runs" and one for the Mac's sleep.
private struct Watched {
  let harness: AgentHarness
  let device: FakeDevice
  let domain: String
  let changes: ChangeWatch
  let clock = ManualClock()
  let busy = Switch()
  let sleeps: AsyncStream<Bool>.Continuation
  let runner: Task<Void, Never>

  init(folders: [String] = ["/Download"]) async throws {
    device = await makeDevice("A")
    for folder in folders {
      try await device.seed(
        path(folder + "/seed.txt"), in: storageID(device), contents: Data("a".utf8))
    }
    harness = try AgentHarness(devices: [device])
    domain = domainID(device)
    _ = await harness.manager.waitForCalls(1)
    let (sleepStream, sleeps) = AsyncStream.makeStream(of: Bool.self)
    self.sleeps = sleeps
    let busy = busy
    changes = ChangeWatch(
      domains: harness.controller, busy: { _ in busy.isOn }, clock: clock,
      sleeps: sleepStream)
    runner = Task { [changes] in await changes.run() }
  }

  var storage: StorageID { storageID(device) }

  func hint(_ folder: String) throws -> FolderHint {
    FolderHint(storage: storage, folder: try path(folder))
  }

  /// Lists `folder` for a client, as Finder does, and tells the watch unless `quietly`, as for
  /// a folder listed before this agent process started.
  func list(_ folder: String, quietly: Bool = false) async throws {
    let id = try await harness.id(try path(folder), in: domain)
    guard case .entries = await harness.service.handle(.list(domain: domain, folder: id), file: nil)
    else { throw TransportError.io("listing failed") }
    if !quietly { await changes.listed(try path(folder), in: domain) }
  }

  func signals() async -> Int {
    await harness.manager.calls.count { $0 == .signal(domain) }
  }

  /// Sends `hints` and lets the window that gathers them close; returns once it has.
  func hint(_ folders: [String]) async throws {
    let (received, windows) = (await changes.hintsReceived, await changes.hintWindows)
    for folder in folders { device.watches.send(try hint(folder)) }
    await changes.waitForHints(received + folders.count)
    await clock.advance(by: ChangeWatch.hintWindow)
    await changes.waitForHintWindows(windows + 1)
  }

  /// Lets one 30 s period pass and returns once its pass is done.
  func tick() async {
    let done = await changes.ticks
    await clock.waitForSleeper()
    await clock.advance(by: ChangeWatch.interval)
    await changes.waitForTicks(done + 1)
  }

  func finish() {
    runner.cancel()
    sleeps.finish()
    harness.finish()
  }
}

@Suite(.timeLimit(.minutes(1)))
struct ChangeWatchTests {
  /// Every 30 s the listed folders are listed again; the domain is signalled only when a
  /// listing differs.
  @Test func thePeriodicListingSignalsOnlyAChange() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    let before = await watched.signals()
    await watched.tick()
    #expect(await watched.signals() == before)
    try await watched.device.seed(
      path("/Download/new.txt"), in: watched.storage, contents: Data("b".utf8))
    await watched.tick()
    #expect(await watched.signals() == before + 1)
  }

  /// After an agent restart no client has listed anything yet: the folders the domain's table
  /// knows as listed are watched and listed again meanwhile.
  @Test func foldersListedBeforeARestartAreCovered() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    // Finder lists the root first, which reports the folder.
    try await watched.list("/", quietly: true)
    try await watched.list("/Download", quietly: true)
    let before = await watched.signals()
    try await watched.device.seed(
      path("/Download/new.txt"), in: watched.storage, contents: Data("b".utf8))
    await watched.tick()
    #expect(await watched.signals() == before + 1)
    let download = try watched.hint("/Download")
    await watched.device.watches.waitUntil { $0.last?.contains(download) == true }
  }

  @Test func nothingIsListedWhileATransferRuns() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    let before = await watched.signals()
    try await watched.device.seed(
      path("/Download/new.txt"), in: watched.storage, contents: Data("b".utf8))
    watched.busy.set(true)
    await watched.tick()
    #expect(await watched.signals() == before)
    watched.busy.set(false)
    await watched.tick()
    #expect(await watched.signals() == before + 1)
  }

  @Test func nothingIsListedWhileTheMacSleeps() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    let before = await watched.signals()
    try await watched.device.seed(
      path("/Download/new.txt"), in: watched.storage, contents: Data("b".utf8))
    watched.sleeps.yield(true)
    await watched.changes.waitForSleepState(true)
    await watched.tick()
    #expect(await watched.signals() == before)
    watched.sleeps.yield(false)
    await watched.changes.waitForSleepState(false)
    await watched.tick()
    #expect(await watched.signals() == before + 1)
  }

  /// The device watches the folders listed most recently, at most 32, newest last.
  @Test func theWatchFollowsTheMostRecentListings() async throws {
    let names = (0..<34).map { "/F\($0)" }
    let watched = try await Watched(folders: names)
    defer { watched.finish() }
    for name in names { try await watched.list(name) }
    let newest = Set(try names.suffix(ChangeWatch.folderLimit).map(watched.hint))
    await watched.device.watches.waitUntil { $0.last.map(Set.init) == newest }
    #expect(watched.device.watches.requests.last?.count == ChangeWatch.folderLimit)
  }

  /// A hint lists its folder again once its short window closes, and a change it finds is
  /// signalled.
  @Test func aHintListsItsFolder() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    await watched.device.watches.waitForRequests(1)
    let before = await watched.signals()
    try await watched.device.seed(
      path("/Download/new.txt"), in: watched.storage, contents: Data("b".utf8))
    try await watched.hint(["/Download"])
    #expect(await watched.signals() == before + 1)
  }

  /// A burst of hints (Ferry deleting many files in a watched folder, say) is gathered into one
  /// listing, not one per hint, and nothing is listed before the window closes.
  @Test func aBurstOfHintsIsOneListing() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    await watched.device.watches.waitForRequests(1)
    let download = try path("/Download")
    let before = await watched.device.listCalls[download] ?? 0
    let received = await watched.changes.hintsReceived
    for _ in 0..<200 { watched.device.watches.send(try watched.hint("/Download")) }
    await watched.changes.waitForHints(received + 200)
    #expect(await watched.device.listCalls[download] ?? 0 == before)
    await watched.clock.advance(by: ChangeWatch.hintWindow)
    await watched.changes.waitForHintWindows(1)
    #expect(await watched.device.listCalls[download] ?? 0 == before + 1)
  }

  /// A hint during a transfer waits, and is acted on by the next pass that finds none.
  @Test func aHintDuringATransferWaits() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    await watched.device.watches.waitForRequests(1)
    let before = await watched.signals()
    try await watched.device.seed(
      path("/Download/new.txt"), in: watched.storage, contents: Data("b".utf8))
    watched.busy.set(true)
    try await watched.hint(["/Download"])
    #expect(await watched.signals() == before)
    watched.busy.set(false)
    await watched.tick()
    #expect(await watched.signals() == before + 1)
  }

  /// A watch that ends (the device's watcher exited) is started again by the next pass.
  @Test func anEndedWatchIsStartedAgain() async throws {
    let watched = try await Watched()
    defer { watched.finish() }
    try await watched.list("/Download")
    await watched.device.watches.waitForRequests(1)
    watched.device.watches.end()
    await watched.changes.waitForEndedWatches(1)
    await watched.tick()
    await watched.device.watches.waitForRequests(2)
    #expect(watched.device.watches.requests.count == 2)
  }

  /// A client's listing through the service reaches the watch.
  @Test func aClientListingIsWatched() async throws {
    let device = await makeDevice("A")
    try await device.seed(path("/Download/a.txt"), in: storageID(device), contents: Data())
    let clock = ManualClock()
    let (sleeps, _) = AsyncStream.makeStream(of: Bool.self)
    let harness = try AgentHarness(
      devices: [device],
      changes: { controller in
        ChangeWatch(domains: controller, busy: { _ in false }, clock: clock, sleeps: sleeps)
      })
    defer { harness.finish() }
    _ = await harness.manager.waitForCalls(1)
    let id = try await harness.id(try path("/Download"), in: domainID(device))
    _ = await harness.service.handle(.list(domain: domainID(device), folder: id), file: nil)
    await device.watches.waitForRequests(1)
    #expect(
      device.watches.requests == [
        [FolderHint(storage: storageID(device), folder: try path("/Download"))]
      ])
  }
}
