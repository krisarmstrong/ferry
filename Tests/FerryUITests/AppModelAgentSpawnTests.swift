import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryUI

/// An agent launchd keeps a job for but cannot spawn: no process runs, and a status sent to it
/// is held rather than failed, as XPC holds a message for a job launchd still lists. Each status
/// held is recorded as "status held" and ends only when its caller cancels it. Once `start()` is
/// called, statuses reach `inner`.
final class UnspawnedAgent: AgentSending {
  let inner: FakeClient
  private let started = Mutex(false)
  private let park = RequestPark()

  init(_ inner: FakeClient) { self.inner = inner }

  var isRunning: Bool { started.withLock { $0 } }
  func start() { started.withLock { $0 = true } }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError) -> AgentResponse {
    if case .status = request, !isRunning {
      inner.log.record("status held")
      await park.waitUntilCancelled()
      throw .cancelled
    }
    return try await inner.send(request, file: file, progress: progress)
  }
}

/// A live agent slow to answer: its status waits at `gate` until the test releases it.
final class SlowAgent: AgentSending {
  let inner: FakeClient
  let gate = RequestGate()

  init(_ inner: FakeClient) {
    self.inner = inner
    gate.hold()
  }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError) -> AgentResponse {
    if case .status = request { await gate.passWhenReleased() }
    return try await inner.send(request, file: file, progress: progress)
  }
}

/// After a build signed by another identity replaces Ferry, launchd keeps the agent's job with
/// the old identity's launch constraint and fails every spawn (`OS_REASON_CODESIGNING`), while
/// the app's status request waits for an answer that never comes. A status with no answer after
/// `AppModel.statusDeadline` and no agent process is a lost connection, which recovery restarts.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelAgentSpawnTests {
  let log = CallLog()

  /// The status deadline passes at once; every other wait too, unless cancelled.
  private func model(_ client: any AgentSending, _ services: FakeServices) -> AppModel {
    AppModel(
      client: client, services: services, sleep: { _ in try Task.checkCancellation() },
      statusDeadline: {})
  }

  private func stuck(_ services: FakeServices) -> UnspawnedAgent {
    let agent = UnspawnedAgent(FakeClient(log: log))
    services.agentEnabled = true
    services.agentRunning = { agent.isRunning }
    return agent
  }

  @Test func aHeldStatusWithNoAgentProcessIsALostConnection() async {
    let services = FakeServices(log: log)
    let model = model(stuck(services), services)
    #expect(await model.readStatus() == .lost)
    #expect(model.agent == .unreachable)
  }

  /// The one real case: the restart at launch did not clear the job, a later one does.
  @Test func anAgentLaunchdCannotSpawnIsRestarted() async {
    let services = FakeServices(log: log)
    let agent = stuck(services)
    services.afterRestart = { agent.start() }
    let model = model(agent, services)
    await model.launch()
    #expect(
      log.all == [
        "registerAgent", "status held", "status held", "restartAgent", "status",
        "registerExtensions", "readLoginItem",
      ])
    #expect(model.agent == .running)
  }

  /// When a restart leaves no agent running, the job is booted out and the agent restarted.
  @Test func anAgentStillNotRunningAfterARestartIsBootedOut() async {
    let services = FakeServices(log: log)
    let agent = stuck(services)
    var restarts = 0
    services.afterRestart = {
      restarts += 1
      if restarts == 2 { agent.start() }
    }
    let model = model(agent, services)
    await model.launch()
    #expect(
      log.all == [
        "registerAgent", "status held", "status held", "restartAgent", "bootOutAgent",
        "restartAgent", "status", "registerExtensions", "readLoginItem",
      ])
    #expect(model.agent == .running)
  }

  /// One restart and at most one bootout per outage, then a bounded number of checks.
  @Test func anAgentThatNeverStartsIsBootedOutOnce() async {
    let services = FakeServices(log: log)
    let model = model(stuck(services), services)
    await model.launch()
    await model.refresh()
    #expect(log.all.filter { $0 == "restartAgent" }.count == 2)
    #expect(log.all.filter { $0 == "bootOutAgent" }.count == 1)
    // The first status, the one asked again, the checks after the restarts, one refresh.
    #expect(log.all.filter { $0 == "status held" }.count == 1 + 1 + AppModel.recoveryChecks + 1)
    #expect(model.agent == .unreachable)
  }

  /// A restart that starts the agent is never followed by a bootout.
  @Test func aRunningAgentIsNeverBootedOut() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    let model = model(FlakyClient(FakeClient(log: log), failures: 2), services)
    await model.launch()
    #expect(log.all.contains("restartAgent"))
    #expect(!log.all.contains("bootOutAgent"))
  }

  /// A live agent past the deadline is slow, not stuck: the status waits for its answer.
  @Test(.timeLimit(.minutes(1)))
  func aSlowLiveAgentIsWaitedFor() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    let agent = SlowAgent(FakeClient(log: log))
    let model = model(agent, services)
    let read = Task { await model.readStatus() }
    for await _ in agent.gate.arrivals { break }
    while services.runningChecks == 0 { await Task.yield() }
    agent.gate.release()
    #expect(await read.value == .answered)
    #expect(!log.all.contains("restartAgent"))
    #expect(model.agent == .running)
  }

  /// Turned off in Login Items: the menu says so after the deadline, and nothing is restarted.
  @Test func aHelperTurnedOffIsShownNotWaitedOn() async {
    let services = FakeServices(log: log)
    let agent = stuck(services)
    services.agentEnabled = false
    services.helper = .requiresApproval
    let model = model(agent, services)
    await model.launch()
    #expect(model.agent == .unreachable)
    #expect(model.helper == .requiresApproval)
    #expect(!log.all.contains("restartAgent"))
  }

  /// The menu closing while the app waits for the restarted agent boots nothing out.
  @Test func closingTheMenuDuringTheStartWaitBootsNothingOut() async {
    let services = FakeServices(log: log)
    let agent = stuck(services)
    let model = model(agent, services)
    let box = TaskBox()
    services.afterRestart = { box.task?.cancel() }
    let refresh = Task { await model.refresh() }
    box.task = refresh
    await refresh.value
    #expect(log.all.contains("restartAgent"))
    #expect(!log.all.contains("bootOutAgent"))
  }

  // MARK: Remove Ferry (review M2)

  /// Removal unregisters the agent, and a refresh meanwhile loses its connection: the agent
  /// being removed is not restarted.
  @Test(.timeLimit(.minutes(1)))
  func aRemovalUnderWayRestartsNothing() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    services.holdsUnregister = true
    let model = model(FlakyClient(FakeClient(log: log), failures: 1000), services)
    let removal = Task { await model.removeFerry() }
    for await _ in services.unregistersHeld { break }
    await model.refresh()
    services.releaseUnregister()
    await removal.value
    #expect(!log.all.contains("restartAgent"))
  }

  /// macOS stops reporting the agent enabled while recovery checks it (the user, or Remove
  /// Ferry, unregistered it): it is not restarted.
  @Test func anAgentDisabledDuringTheChecksIsNotRestarted() async {
    let services = FakeServices(log: log)
    services.agentEnabledAnswers = [true, false]
    let model = model(FlakyClient(FakeClient(log: log), failures: 1000), services)
    await model.refresh()
    #expect(!log.all.contains("restartAgent"))
  }
}

/// Holds a task for a hook that runs on the main actor.
@MainActor
final class TaskBox {
  var task: Task<Void, Never>?
}
