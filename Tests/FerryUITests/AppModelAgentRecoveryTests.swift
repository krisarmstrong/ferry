import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerryUI

/// Answers status as `inner` once `failures` status requests have failed, and records each
/// failed one as "status unreachable".
final class FlakyClient: AgentSending {
  let inner: FakeClient
  private let failures: Mutex<Int>

  init(_ inner: FakeClient, failures: Int) {
    self.inner = inner
    self.failures = Mutex(failures)
  }

  func setFailures(_ count: Int) { failures.withLock { $0 = count } }

  func send(
    _ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?
  ) async throws(TransportError) -> AgentResponse {
    if case .status = request {
      let fails = failures.withLock { count in
        defer { count = max(0, count - 1) }
        return count > 0
      }
      if fails {
        inner.log.record("status unreachable")
        throw .deviceDisconnected
      }
    }
    return try await inner.send(request, file: file, progress: progress)
  }
}

/// After a build signed by another identity is installed, launchd can keep the old job: it says
/// `spawn failed` (`OS_REASON_CODESIGNING`, `EX_CONFIG`) and never starts the agent, while
/// `SMAppService` reports it enabled. The app restarts the agent once when it cannot reach it and
/// macOS says it is enabled, then checks a few times.
@MainActor
struct AppModelAgentRecoveryTests {
  let log = CallLog()

  private func model(_ client: any AgentSending, _ services: FakeServices) -> AppModel {
    AppModel(client: client, services: services, sleep: { _ in })
  }

  @Test func anEnabledAgentThatCannotBeReachedIsRestartedOnce() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    let client = FlakyClient(FakeClient(log: log), failures: 1)
    let model = model(client, services)
    await model.launch()
    #expect(
      log.all == [
        "registerAgent", "registerExtensions", "status unreachable", "restartAgent", "status",
        "readLoginItem",
      ])
    #expect(model.agent == .running)
  }

  /// Turned off, or waiting for approval: the user's setting, not a stuck job.
  @Test func anAgentMacOSDoesNotHaveEnabledIsLeftAlone() async {
    let services = FakeServices(log: log)
    services.agentEnabled = false
    let model = model(FlakyClient(FakeClient(log: log), failures: 1), services)
    await model.launch()
    #expect(!log.all.contains("restartAgent"))
    #expect(model.agent == .unreachable)
  }

  /// The app itself was replaced: the new agent refuses this copy, which only a relaunch fixes.
  @Test func aReplacedAppDoesNotRestartTheAgent() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    services.replaced = true
    let model = model(FlakyClient(FakeClient(log: log), failures: 1), services)
    await model.launch()
    #expect(!log.all.contains("restartAgent"))
    #expect(model.agent == .replaced)
  }

  /// A restart cuts off every transfer: one per outage, checked a bounded number of times, and
  /// another only once the agent has answered and gone away again.
  @Test func oneRestartPerOutageWithBoundedChecks() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    let client = FlakyClient(FakeClient(log: log), failures: 1000)
    let model = model(client, services)
    await model.launch()
    await model.refresh()
    await model.refresh()
    #expect(log.all.filter { $0 == "restartAgent" }.count == 1)
    let checks = log.all.filter { $0 == "status unreachable" }.count
    #expect(checks == 1 + AppModel.recoveryChecks + 2)
    #expect(model.agent == .unreachable)

    client.setFailures(0)
    await model.refresh()
    #expect(model.agent == .running)
    client.setFailures(1)
    await model.refresh()
    #expect(log.all.filter { $0 == "restartAgent" }.count == 2)
  }

  /// The menu refreshes every 2 s and after each action: refreshes that overlap restart once.
  @Test func overlappingRefreshesRestartOnce() async {
    let services = FakeServices(log: log)
    services.agentEnabled = true
    let model = model(FlakyClient(FakeClient(log: log), failures: 1000), services)
    async let first: Void = model.refresh()
    async let second: Void = model.refresh()
    _ = await (first, second)
    #expect(log.all.filter { $0 == "restartAgent" }.count == 1)
  }

  /// `register()` succeeds even when launchd then fails to spawn the agent. Recording the build
  /// then would leave every later launch only registering the stuck job: it is recorded once the
  /// agent answers.
  @Test func aRestartIsRecordedOnlyOnceTheAgentAnswers() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-2"
    services.startedAgent = "agent-1"
    await model(FlakyClient(FakeClient(log: log), failures: 1000), services).launch()
    #expect(services.startedAgent == "agent-1")
    #expect(!log.all.contains { $0.hasPrefix("recordStartedAgent") })

    await model(FakeClient(log: log), services).launch()
    #expect(services.startedAgent == "agent-2")
    #expect(
      log.all.suffix(5) == [
        "restartAgent", "registerExtensions", "status", "recordStartedAgent agent-2",
        "readLoginItem",
      ])
  }
}
