import Testing

@testable import FerryUI

/// After an update the agent still running is the old one, which would serve the new app old
/// code until the next login. Launch restarts it whenever the agent in the bundle is not the one
/// it was last started from.
@MainActor
struct AppModelAgentRestartTests {
  let log = CallLog()

  @Test func unchangedAgentIsOnlyRegistered() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-1"
    services.startedAgent = "agent-1"
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(log.all == ["registerAgent", "status", "readLoginItem"])
  }

  @Test func updatedAgentIsRestartedBeforeTheFirstStatus() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-2"
    services.startedAgent = "agent-1"
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(
      log.all == ["restartAgent", "recordStartedAgent agent-2", "status", "readLoginItem"])
    #expect(services.startedAgent == "agent-2")
  }

  /// The first launch, or the first after an update from a Ferry that recorded nothing: the agent
  /// running, if any, may be anything.
  @Test func agentNeverRecordedIsRestarted() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-1"
    services.startedAgent = nil
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(
      log.all == ["restartAgent", "recordStartedAgent agent-1", "status", "readLoginItem"])
  }

  /// Without the agent's identity there is nothing to compare: registering is harmless, and a
  /// restart on every launch would cut off every transfer at each one.
  @Test func unreadableAgentIsOnlyRegistered() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = nil
    services.startedAgent = "agent-1"
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(log.all == ["registerAgent", "status", "readLoginItem"])
    #expect(services.startedAgent == "agent-1")
  }
}
