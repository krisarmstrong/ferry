import DeviceKit
import FerryIPC
import Foundation
import Synchronization
import Testing

@testable import FerrySyncCore

/// Answers `.devices` with each call's devices, after each call's delay, and counts the calls.
private final class ScriptedAgent: AgentSending {
  private let replies: [(devices: [DeviceSummary], delay: Duration)]
  private let calls = Atomic(0)

  init(_ replies: [(devices: [DeviceSummary], delay: Duration)]) {
    self.replies = replies
  }

  var count: Int { calls.load(ordering: .relaxed) }

  func send(_ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?)
    async throws(TransportError) -> AgentResponse
  {
    let call = calls.add(1, ordering: .relaxed).oldValue
    let reply = replies[min(call, replies.count - 1)]
    try? await Task.sleep(for: reply.delay)
    guard request == .devices else { return .failure(.io("unexpected")) }
    return .devices(reply.devices)
  }
}

private struct UnreachableAgent: AgentSending {
  func send(_ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?)
    async throws(TransportError) -> AgentResponse
  {
    throw .deviceDisconnected
  }
}

/// Finder asks for its menu synchronously: the list answers from the agent when it is quick, and
/// from the last answer when it is not.
@Suite(.timeLimit(.minutes(1)))
struct DeviceListTests {
  @Test func aQuickAgentGivesTheCurrentDevices() {
    let device = attached("A", model: "LinkRunner")
    let list = DeviceList(agent: ScriptedAgent([([device], .zero)]))
    #expect(list.fresh(waitingUpTo: .seconds(5)) == [device])
  }

  @Test func aSlowAgentGivesTheLastAnswer() async {
    let device = attached("A", model: "LinkRunner")
    let list = DeviceList(agent: ScriptedAgent([([device], .seconds(2))]))
    #expect(list.fresh(waitingUpTo: .milliseconds(50)) == [])
    await list.refresh()
    #expect(list.fresh(waitingUpTo: .milliseconds(50)) == [device])
  }

  /// No agent means no device to send to, not the devices it last reported.
  @Test func anUnreachableAgentHasNoDevices() async {
    let list = DeviceList(agent: UnreachableAgent())
    await list.refresh()
    #expect(list.fresh(waitingUpTo: .seconds(5)) == [])
  }

  /// A late answer to an earlier request never replaces a newer one.
  @Test func aLateAnswerDoesNotReplaceANewerOne() async throws {
    let device = attached("A", model: "LinkRunner")
    let list = DeviceList(agent: ScriptedAgent([([device], .milliseconds(500)), ([], .zero)]))
    async let first: Void = list.refresh()
    try await Task.sleep(for: .milliseconds(100))
    await list.refresh()
    await first
    #expect(list.current == [])
  }

  /// An agent that never answers holds one request, not one per right-click.
  @Test func menusWhileARequestIsPendingAskNothingMore() {
    let agent = ScriptedAgent([([], .seconds(10))])
    let list = DeviceList(agent: agent)
    for _ in 0..<5 {
      #expect(list.fresh(waitingUpTo: .milliseconds(20)) == [])
    }
    #expect(agent.count == 1)
  }
}
