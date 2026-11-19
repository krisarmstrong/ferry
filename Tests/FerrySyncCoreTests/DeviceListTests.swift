import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerrySyncCore

/// Answers `.status` with `devices`, after `delay`.
private struct StatusAgent: AgentSending {
  let devices: [AttachedDevice]
  let delay: Duration

  func send(_ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?)
    async throws(TransportError) -> AgentResponse
  {
    try? await Task.sleep(for: delay)
    guard request == .status else { return .failure(.io("unexpected")) }
    return .status(StatusReport(devices: devices, provider: .enabled))
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
    let list = DeviceList(agent: StatusAgent(devices: [device], delay: .zero))
    #expect(list.fresh(waitingUpTo: .seconds(5)) == [device])
  }

  @Test func aSlowAgentGivesTheLastAnswer() async {
    let device = attached("A", model: "LinkRunner")
    let list = DeviceList(agent: StatusAgent(devices: [device], delay: .seconds(2)))
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
}
