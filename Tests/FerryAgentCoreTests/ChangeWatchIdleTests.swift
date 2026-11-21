import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// The 30 s relisting runs only while a Ferry location on the device is in use: Finder listed,
/// opened or changed something on it in the last `idlePasses` passes (audit M3). A phone left
/// plugged in with Finder closed is not listed every 30 s all day.
@Suite(.timeLimit(.minutes(1)))
struct ChangeWatchIdleTests {
  /// A domain with one listed folder, the agent wired to the change watch, and its clock.
  private struct Fixture {
    let harness: AgentHarness
    let device: FakeDevice
    let domain: String
    let clock = ManualClock()
    let changes: ChangeWatch
    let sleeps: AsyncStream<Bool>.Continuation
    let runner: Task<Void, Never>

    init() async throws {
      device = await makeDevice("A")
      try await device.seed(
        path("/Download/seed.txt"), in: storageID(device), contents: Data("a".utf8))
      let (sleepStream, sleeps) = AsyncStream.makeStream(of: Bool.self)
      self.sleeps = sleeps
      let clock = clock
      harness = try AgentHarness(devices: [device]) { controller in
        ChangeWatch(domains: controller, busy: { _ in false }, clock: clock, sleeps: sleepStream)
      }
      domain = domainID(device)
      _ = await harness.manager.waitForCalls(1)
      let changes = try #require(await harness.service.changes)
      self.changes = changes
      runner = Task { await changes.run() }
    }

    func list(_ folder: String) async throws -> ItemID {
      let id = try await harness.id(try path(folder), in: domain)
      _ = await harness.service.handle(.list(domain: domain, folder: id), file: nil)
      return id
    }

    func signals() async -> Int {
      await harness.manager.calls.count { $0 == .signal(domain) }
    }

    func tick() async {
      let done = await changes.ticks
      await clock.waitForSleeper()
      await clock.advance(by: ChangeWatch.interval)
      await changes.waitForTicks(done + 1)
    }

    func addFile(_ name: String) async throws {
      try await device.seed(
        path("/Download/\(name)"), in: storageID(device), contents: Data("b".utf8))
    }

    func finish() {
      runner.cancel()
      sleeps.finish()
      harness.finish()
    }
  }

  @Test func relistingStopsOnceNothingUsesTheDevice() async throws {
    let fixture = try await Fixture()
    defer { fixture.finish() }
    _ = try await fixture.list("/Download")
    for _ in 0..<ChangeWatch.idlePasses { await fixture.tick() }
    let before = await fixture.signals()
    try await fixture.addFile("new.txt")
    await fixture.tick()
    #expect(await fixture.signals() == before)
  }

  /// Opening an item through Finder (any request on the domain) starts the relisting again.
  @Test func aRequestResumesRelisting() async throws {
    let fixture = try await Fixture()
    defer { fixture.finish() }
    let folder = try await fixture.list("/Download")
    for _ in 0..<ChangeWatch.idlePasses { await fixture.tick() }
    _ = await fixture.harness.service.handle(
      .item(domain: fixture.domain, id: folder), file: nil)
    let before = await fixture.signals()
    try await fixture.addFile("new.txt")
    await fixture.tick()
    #expect(await fixture.signals() > before)
  }
}
